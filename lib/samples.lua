-- lib/samples.lua
-- A file's settings (3.7, design §4, decision 10), S.lib.samples: what
-- Strata knows about the audio each buffer slot holds (a tempo, a key,
-- normalize, how it is sliced), remembered per file and start point in
-- data/strata/samples.data, and for a take (the slot's scratch path) per
-- slot in buffers.data. The one module that reads or writes a slot's
-- settings or samples.data. lib/buffers.lua and lib/record.lua bind a slot
-- where its state settles (a load that took effect, a take's end, the
-- restore, a failed load's undo) and unbind it where it empties (a clear,
-- a replace take's start); each bind and unbind tells the on_bind
-- listeners and resends scaleNote and rootNote to the running voices that
-- read the slot. The normalize gain is sent from the peaks listener
-- (S.lib.waveforms.on_read), never at a bind. Start step samples_load,
-- cleanup step samples_save. See docs/notes/lua/samples.md.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The tunables: the file, its version and its most entries; the largest
  -- gain; the tempo's range; the slice modes and the defaults of their
  -- count and sensitivity; the count's and the key's ranges, the
  -- sensitivity's top, a bar's beats, the write's delay and the backup's
  -- suffix
  local SAMPLES = {file = "samples.data", version = 1, max_files = 256, max_gain = 16, tempo_min = 20,
    tempo_max = 300, modes = {"off", "equal", "transients"}, default_count = 8, default_sensitivity = 50,
    count_min = 2, count_max = 64, sensitivity_max = 100, key_max = 127, beats_per_bar = 4,
    seconds_per_minute = 60, save_delay = 0.1, backup_suffix = ".bak"}
  M.SAMPLES = SAMPLES

  -- A record's fields, in the order they are copied and compared
  local FIELDS = {"tempo", "key", "normalize", "mode", "count", "sensitivity", "edited", "markers", "frames", "rate"}

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end
  local function whole_in(value, low, high)
    return finite(value) and value % 1 == 0 and value >= low and value <= high
  end
  local function valid_slot(slot) return S.lib.buffers.valid_buffer_slot(slot) end

  -- markers: nil, or a list of whole frames, ascending, the first 0, at
  -- most count_max of them
  local function valid_markers(value)
    if value == nil then return true end
    if type(value) ~= "table" or #value < 1 or #value > SAMPLES.count_max or value[1] ~= 0 then return false end
    local entries = 0
    for _ in pairs(value) do entries = entries + 1 end
    if entries ~= #value then return false end
    for index, frame in ipairs(value) do
      if not whole_in(frame, 0, math.huge) or (index > 1 and frame <= value[index - 1]) then return false end
    end
    return true
  end

  -- Each field's check
  local CHECKS = {
    tempo = function(value) return value == nil or (finite(value) and value >= SAMPLES.tempo_min
      and value <= SAMPLES.tempo_max) end,
    key = function(value) return value == nil or whole_in(value, 0, SAMPLES.key_max) end,
    normalize = function(value) return type(value) == "boolean" end,
    mode = function(value) return whole_in(value, 1, #SAMPLES.modes) end,
    count = function(value) return whole_in(value, SAMPLES.count_min, SAMPLES.count_max) end,
    sensitivity = function(value) return finite(value) and value >= 0 and value <= SAMPLES.sensitivity_max end,
    edited = function(value) return type(value) == "boolean" end,
    markers = valid_markers,
    frames = function(value) return value == nil or (whole_in(value, 1, math.huge)) end,
    rate = function(value) return value == nil or (finite(value) and value > 0) end,
  }

  local function default_record()
    return {normalize = false, mode = 1, count = SAMPLES.default_count, sensitivity = SAMPLES.default_sensitivity,
      edited = false}
  end
  local DEFAULT = default_record()

  local function copy_value(value)
    if type(value) ~= "table" then return value end
    local list = {}
    for index, item in ipairs(value) do list[index] = item end
    return list
  end

  local function copy_record(record)
    local copy = {}
    for _, field in ipairs(FIELDS) do copy[field] = copy_value(record[field]) end
    return copy
  end

  -- Whether a record holds only defaults (it is then not kept in a file)
  local function is_default(record)
    for _, field in ipairs(FIELDS) do
      if record[field] ~= DEFAULT[field] then return false end
    end
    return true
  end

  -- A stored value as a record (missing fields at their defaults), or nil
  -- when any known field fails its check
  local function record_from(value)
    if type(value) ~= "table" then return nil end
    local record = default_record()
    for _, field in ipairs(FIELDS) do
      if value[field] ~= nil then
        if not CHECKS[field](value[field]) then return nil end
        record[field] = copy_value(value[field])
      end
    end
    return record
  end

  -- What is known: the files' entries {path, start, used, settings}, a
  -- take's record per slot, what each slot is bound to (OWN: the slot's
  -- own record; an entry: that file's; nil: unbound), the listeners, the
  -- counter `used` takes its stamps from, and the file's state
  local OWN = {}
  local entries = {}
  local own = {}
  local bound = {}
  local listeners = {}
  local listener_errors = {}
  local use_count = 0
  local store = {started = false, blocked = false, text = nil, save_clock = nil}

  local function samples_path() return S.lib.scenes.scene_data_dir .. SAMPLES.file end

  local function find(path, start)
    for _, entry in ipairs(entries) do
      if entry.path == path and entry.start == start then return entry end
    end
    return nil
  end

  local function bound_anywhere(entry)
    for slot = 1, NUM_BUFFERS do
      if bound[slot] == entry then return true end
    end
    return false
  end

  -- Unbound entries at their defaults go (they hold nothing); past
  -- max_files, the unbound ones least recently used
  local function prune()
    for index = #entries, 1, -1 do
      if is_default(entries[index].settings) and not bound_anywhere(entries[index]) then
        table.remove(entries, index)
      end
    end
    while #entries > SAMPLES.max_files do
      local lowest = nil
      for index, entry in ipairs(entries) do
        if not bound_anywhere(entry) and (lowest == nil or entry.used < entries[lowest].used) then lowest = index end
      end
      if not lowest then return end
      table.remove(entries, lowest)
    end
  end

  -- What samples.data holds: the entries not at their defaults, the most
  -- recently used first, at most max_files
  local function stored_value()
    local kept = {}
    for _, entry in ipairs(entries) do
      if not is_default(entry.settings) then kept[#kept + 1] = entry end
    end
    table.sort(kept, function(a, b) return a.used > b.used end)
    local files = {}
    for index = 1, math.min(#kept, SAMPLES.max_files) do
      local entry = kept[index]
      files[index] = {path = entry.path, start = entry.start, used = entry.used, settings = copy_record(entry.settings)}
    end
    return {version = SAMPLES.version, files = files}
  end

  local function write()
    if not store.started or store.blocked then return end
    util.make_dir(S.lib.scenes.scene_data_dir)
    local value = stored_value()
    local written, problem = S.lib.data_files.write(samples_path(), value)
    if not written then
      print("strata: " .. SAMPLES.file .. " not saved: " .. tostring(problem))
      return
    end
    store.text = S.lib.data_files.encode(value)
  end

  -- One write save_delay s after the first change of a burst, when what
  -- the file would hold differs from what was last written
  local function schedule_save()
    if not store.started or store.blocked or store.save_clock then return end
    if S.lib.data_files.encode(stored_value()) == store.text then return end
    store.save_clock = clock.run(function()
      clock.sleep(SAMPLES.save_delay)
      store.save_clock = nil
      write()
    end)
  end

  -- A record changed: its file is written (a take's: buffers.data)
  local function changed(slot)
    if bound[slot] == OWN then S.lib.buffers.remember() else schedule_save() end
  end

  -- The running voices reading the slot get scaleNote and rootNote again
  local function resend(slot)
    for voice_idx = 1, NUM_VOICES do
      if S.voices[voice_idx].active and voice_buffer_slot(voice_idx) == slot then
        S.lib.variation.send_scale_note(voice_idx)
        S.lib.variation.send_root_note(voice_idx)
      end
    end
  end

  local function tell(slot)
    for index, fn in ipairs(listeners) do
      S.lib.ui_frame.contained_call(listener_errors, index, "samples bind listener " .. index, fn, slot)
    end
  end

  -- The live record of what the slot holds (a default one made on first
  -- use), or nil for a slot with no audio or none bound
  function M.settings(slot)
    if not valid_slot(slot) or bound[slot] == nil or S.buffers[slot].seconds <= 0 then return nil end
    if bound[slot] == OWN then
      own[slot] = own[slot] or default_record()
      return own[slot]
    end
    return bound[slot].settings
  end

  -- fn(slot) at every bind and unbind, contained
  function M.on_bind(fn)
    assert(type(fn) == "function", "on_bind: a listener is a function")
    listeners[#listeners + 1] = fn
  end

  -- The slot's state settled: bind it to its take's record (a scratch path,
  -- or a take with none) or its file's (path and start), raising the
  -- file's `used`; a file drops the slot's own record (it was loaded over)
  function M.bind(slot)
    if not valid_slot(slot) then return end
    local buffer = S.buffers[slot]
    local path = buffer.path
    if type(path) == "string" and path ~= scratch_take_path(slot) then
      local start = buffer.sent_start or 0
      local entry = find(path, start)
      if not entry then
        entry = {path = path, start = start, used = 0, settings = default_record()}
        entries[#entries + 1] = entry
      end
      use_count = use_count + 1
      entry.used = use_count
      bound[slot] = entry
      own[slot] = nil
      prune()
      schedule_save()
    else
      bound[slot] = OWN
    end
    tell(slot)
    resend(slot)
  end

  -- The slot emptied (a clear, a replace take's start, a load that settled
  -- with no audio)
  function M.unbind(slot)
    if not valid_slot(slot) then return end
    bound[slot] = nil
    tell(slot)
    resend(slot)
  end

  -- A clear or a replace take's end: the slot's own record goes
  function M.drop_own(slot)
    if valid_slot(slot) then own[slot] = nil end
  end

  -- A playable recording ended (lib/record.lua): the slot holds a take now,
  -- which starts as a copy of the file's record it was recorded over (a
  -- take dubbed keeps its own; an empty slot's take has none). The file's
  -- own record is untouched. The caller binds next
  function M.take_from_file(slot)
    if not valid_slot(slot) then return end
    local was = bound[slot]
    if was ~= nil and was ~= OWN then own[slot] = copy_record(was.settings)
    elseif was == nil then own[slot] = nil end
  end

  -- A copy of the slot's record for a save, or nil when it holds only
  -- defaults (lib/buffers.lua's send_save, a whole save)
  function M.snapshot(slot)
    local record = M.settings(slot)
    if not record or is_default(record) then return nil end
    return copy_record(record)
  end

  -- A whole save succeeded: the saved file's entry (start 0) takes the
  -- record the save was sent with
  function M.store_file(path, record)
    if type(path) ~= "string" or type(record) ~= "table" then return end
    local entry = find(path, 0)
    if not entry then
      entry = {path = path, start = 0, used = 0, settings = default_record()}
      entries[#entries + 1] = entry
    end
    local copy = copy_record(record)
    for _, field in ipairs(FIELDS) do entry.settings[field] = copy[field] end
    use_count = use_count + 1
    entry.used = use_count
    prune()
    schedule_save()
  end

  -- buffers.data's value for the slot: its take's record when it holds a
  -- take whose record is not at its defaults, else false
  function M.stored_own(slot)
    if not valid_slot(slot) or S.buffers[slot].path ~= scratch_take_path(slot) then return false end
    local record = own[slot]
    if not record or is_default(record) then return false end
    return copy_record(record)
  end

  -- buffers.data's restore: a take's record, put in place before its
  -- load settles (a damaged one is dropped, with one console line)
  function M.restore_own(slot, value)
    if not valid_slot(slot) or value == false or value == nil then return end
    local record = record_from(value)
    if not record then
      print("strata: buffer " .. slot .. "'s take settings in buffers.data are damaged: not used")
      return
    end
    own[slot] = record
  end

  -- Set a field of the slot's record: false when the slot has none or the
  -- value fails its check (nothing changes), else true. The record's file
  -- is written soon; a key resends scaleNote and rootNote, normalize the gain
  function M.set(slot, field, value)
    local record = M.settings(slot)
    if not record or not CHECKS[field] or not CHECKS[field](value) then return false end
    if type(value) ~= "table" and record[field] == value then return true end
    record[field] = copy_value(value)
    changed(slot)
    if field == "key" then resend(slot) end
    if field == "normalize" then M.send_gain(slot) end
    request_redraw()
    return true
  end

  -- The key of the file a buffer voice reads, or nil
  local function voice_key(voice)
    if not whole_in(voice, 1, NUM_VOICES) or not voice_uses_buffer(voice) then return nil end
    local record = M.settings(voice_buffer_slot(voice))
    return record and record.key
  end

  -- The note that plays rate 1 on the voice: its file's key, else 60
  function M.rate_root(voice)
    return voice_key(voice) or S.lib.notes.NOTES.rate_root_note
  end

  -- The voice's quantize reference: its file's key, else nil (the caller
  -- keeps the scale's root + 60)
  function M.scale_reference(voice) return voice_key(voice) end

  function M.tempo(slot)
    local record = M.settings(slot)
    return record and record.tempo
  end

  -- The 4-beat bars the slot's valid region holds at its tempo, or nil
  function M.bars(slot)
    local tempo = M.tempo(slot)
    if not tempo then return nil end
    return S.buffers[slot].seconds * tempo / (SAMPLES.seconds_per_minute * SAMPLES.beats_per_bar)
  end

  -- Set the tempo that makes the region exactly `bars` bars: false when it
  -- falls outside tempo_min..tempo_max
  function M.set_bars(slot, bars)
    if not M.settings(slot) or not finite(bars) or bars <= 0 then return false end
    local tempo = bars * SAMPLES.seconds_per_minute * SAMPLES.beats_per_bar / S.buffers[slot].seconds
    return M.set(slot, "tempo", tempo)
  end

  -- The slot's gain: 1 unless normalize; else 1 / its largest peak, at most
  -- max_gain, and 1 while no peaks are read or the peak is 0 or 1
  function M.gain(slot)
    local record = M.settings(slot)
    if not record or not record.normalize then return 1 end
    local peaks = S.lib.waveforms.peaks(slot)
    if not peaks then return 1 end
    local peak = 0
    for _, value in ipairs(peaks) do peak = math.max(peak, value) end
    if peak <= 0 or peak >= 1 then return 1 end
    return math.min(SAMPLES.max_gain, 1 / peak)
  end

  -- Send the slot's gain, unless it records: the engine plays a recording
  -- at 1 (its end's peaks send it again)
  function M.send_gain(slot)
    if not valid_slot(slot) or S.lib.record.state(slot) ~= nil then return end
    engine.setSlotGain(slot - 1, M.gain(slot))
  end

  -- The peaks of what the slot holds were read: a normalized slot's gain
  -- goes to the engine (a reload of the same file reset it to 1)
  S.lib.waveforms.on_read(function(slot)
    local record = M.settings(slot)
    if record and record.normalize then M.send_gain(slot) end
  end)

  -- Why a stored value cannot be used, or nil
  local function problem_with(value)
    if type(value) ~= "table" then return "not a table" end
    if value.version ~= SAMPLES.version then
      return "version " .. tostring(value.version) .. ", expected " .. SAMPLES.version
    end
    if type(value.files) ~= "table" then return "no file list" end
    return nil
  end

  -- The start step: read samples.data (parsed, never run). Missing: no
  -- settings. Unreadable or another version: set aside, one console line,
  -- and nothing is written over it if it cannot be moved. An entry whose
  -- path, start or settings are damaged is left out
  S.register_start(S.constants.START_ORDER.samples_load, function()
    entries, own, bound, use_count = {}, {}, {}, 0
    store.started, store.blocked, store.text = true, false, nil
    local path = samples_path()
    local value, outcome, why = S.lib.data_files.read(path)
    if value == nil and outcome == "missing" then return end
    local problem = value == nil and (why or outcome) or problem_with(value)
    if problem then
      local backup, failure = S.lib.data_files.set_aside(path, SAMPLES.backup_suffix)
      if not backup then store.blocked = true end
      print("strata: " .. SAMPLES.file .. " not used (" .. tostring(problem) .. "): no file has settings; "
        .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure))))
      return
    end
    for _, stored in ipairs(value.files) do
      local record = type(stored) == "table" and record_from(stored.settings) or nil
      if record and type(stored.path) == "string" and finite(stored.start) and stored.start >= 0
        and whole_in(stored.used, 0, math.huge) and not find(stored.path, stored.start)
        and #entries < SAMPLES.max_files then
        entries[#entries + 1] = {path = stored.path, start = stored.start, used = stored.used, settings = record}
        use_count = math.max(use_count, stored.used)
      end
    end
    store.text = S.lib.data_files.encode(stored_value())
  end)

  -- The cleanup step: the waiting write is canceled and the file written
  -- (skipped if the start step never ran, or the file could not be moved)
  S.register_cleanup(S.constants.CLEANUP_ORDER.samples_save, function()
    if store.save_clock then
      clock.cancel(store.save_clock)
      store.save_clock = nil
    end
    write()
  end)

  return M
end

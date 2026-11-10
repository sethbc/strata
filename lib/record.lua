-- lib/record.lua
-- Recording: record_buffer, the take timers (S.buffer_record_clocks) and
-- how a take settles, moved out of lib/buffers.lua. The slots themselves,
-- the polls' decoding and settle_buffer_slot stay in lib/buffers.lua. The
-- recordBuffer arguments come from the record params (3.3).
-- finish_buffer_take is also S.finish_buffer_take, where the tests reach it.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local BUFFER_SETTLE = S.lib.buffers.BUFFER_SETTLE

  -- per slot: clock that ends the recording state, then the finishing fallback
  S.buffer_record_clocks = {}
  -- per slot, while a take records: what S.lib.record.state reports
  local takes = {}

  -- Cancel the slot's recording timer or finishing fallback, if any
  function M.cancel_timer(slot)
    if S.buffer_record_clocks[slot] then
      clock.cancel(S.buffer_record_clocks[slot])
      S.buffer_record_clocks[slot] = nil
    end
  end

  -- Cancel every take timer (the cleanup step of lib/buffers.lua's polls)
  function M.stop_all()
    for slot = 1, NUM_BUFFERS do
      M.cancel_timer(slot)
    end
  end

  -- The recording ended (its timer ran out or it was stopped early): the slot
  -- stays recording, finishing, until the engine reports what it captured, or
  -- BUFFER_SETTLE.fallback_seconds pass without a report. The fallback only
  -- matters when the bufferState poll is missing: with the poll, its periodic
  -- report settles a take within about 2 s. Without it the last known seconds
  -- is 0, so the take settles empty: the fallback exists so K3 is never
  -- ignored forever, not to recover audio.
  local function finish_buffer_take(slot)
    local buffer = S.buffers[slot]
    buffer.finishing = true
    buffer.confirm_since = util.time()
    S.buffer_record_clocks[slot] = clock.run(function()
      clock.sleep(BUFFER_SETTLE.fallback_seconds)
      S.buffer_record_clocks[slot] = nil
      if buffer.finishing then
        settle_buffer_slot(slot)
        S.lib.buffers.display_changed()
      end
    end)
  end

  -- The record group's params (design 1.1), after the buffers group's: PSETs
  -- only, never scene fields. record_duration and record_level stay in the
  -- buffers group.
  local THRESHOLD_DB = {-48, -42, -36, -30, -24, -18, -12, -6}
  local THRESHOLD_OPTIONS = {"off"}
  for _, db in ipairs(THRESHOLD_DB) do THRESHOLD_OPTIONS[#THRESHOLD_OPTIONS + 1] = db .. " dB" end
  local SYNC_OPTIONS = {"off", "beat", "bar"}
  local MAX_RECORD_BEATS = 64

  function M.add_params()
    params:add_group("strata_record", "record", 6)
    params:add_option("record_source", "record source", S.constants.RECORD_SOURCES, 1)
    params:add{type = "control", id = "record_feedback", name = "record feedback",
      controlspec = controlspec.new(0, 100, "lin", 0, 0, "%", 0.01)}
    params:add_option("record_loop", "record loop", {"off", "on"}, 1)
    params:add_option("record_threshold", "record threshold", THRESHOLD_OPTIONS, 1)
    params:add_option("record_sync", "record sync", SYNC_OPTIONS, 1)
    params:add_number("record_beats", "record beats", 1, MAX_RECORD_BEATS, 16)
  end

  -- The delay (s) to the next beat or bar, at least lead_seconds ahead
  -- (design 1.6); 0 without sync
  local function sync_delay()
    local sync = params:get("record_sync")
    if sync == 1 then return 0 end
    local quantum = sync == 2 and 1 or S.constants.RECORD_SYNC.beats_per_bar
    local beat_seconds = clock.get_beat_sec()
    local now = clock.get_beats()
    local lead = S.constants.RECORD_SYNC.lead_seconds / beat_seconds
    local target = math.ceil((now + lead) / quantum) * quantum
    return (target - now) * beat_seconds
  end

  -- Start the take timer: `seconds` later the take finishes
  local function start_take_timer(slot, seconds)
    M.cancel_timer(slot)
    S.buffer_record_clocks[slot] = clock.run(function()
      clock.sleep(seconds)
      S.buffer_record_clocks[slot] = nil
      finish_buffer_take(slot)
      S.lib.buffers.display_changed()
    end)
  end

  -- Record into a slot with the record params, or, if the slot is armed or
  -- recording, stop (K3: a recording keeps what it captured, an armed one is
  -- canceled). A replace take that has ended and waits for the engine
  -- (finishing) ignores the press.
  function record_buffer(slot)
    if not S.lib.buffers.valid_buffer_slot(slot) then return end
    local buffer = S.buffers[slot]
    if buffer.finishing then return end
    if buffer.recording then
      engine.stopRecord(slot - 1)
      -- a playable recording ends with the engine's "ended" report; a take
      -- settles from the engine's seconds (or its fallback)
      if takes[slot] and takes[slot].kind == "take" then
        M.cancel_timer(slot)
        finish_buffer_take(slot)
      end
    else
      M.cancel_timer(slot)
      local feedback = params:get("record_feedback") / 100
      local loop = params:get("record_loop") == 2
      local threshold = 0
      local threshold_index = params:get("record_threshold")
      if threshold_index > 1 then threshold = 10 ^ (THRESHOLD_DB[threshold_index - 1] / 20) end
      local delay = sync_delay()
      local seconds = params:get("record_duration")
      if params:get("record_sync") > 1 then seconds = params:get("record_beats") * clock.get_beat_sec() end
      -- at most what a slot holds on this tier (the param's range already
      -- ends there; a value set before the range was known never passes it)
      seconds = math.min(seconds, S.performance.buffer_seconds)
      -- a playable recording keeps the slot playing; one into a slot at
      -- another sample rate is a replace take (the engine decides the same)
      local playable = feedback > 0 or loop
      local rate = buffer.sample_rate
      if playable and rate and rate ~= S.constants.NORNS_SAMPLE_RATE then
        playable = false
        loop = false  -- a replace take ends at its length
        buffer_page_flash("buf " .. slot .. ": replaced (rate)")
      end
      engine.recordBuffer(slot - 1, seconds, params:get("record_level"), feedback, params:get("record_source") - 1,
        threshold, loop and 1 or 0, delay)
      buffer.records_sent = buffer.records_sent + 1
      local armed = delay > 0 or threshold > 0
      takes[slot] = {number = buffer.records_sent, kind = playable and "playable" or "take",
        phase = armed and "armed" or "recording", started_at = (not armed) and util.time() or nil,
        seconds = seconds, loop = loop}
      S.lib.buffers.recording_started(slot, playable)
      buffer.recording = true
      buffer.pending_loads = {}  -- a failure reported for an earlier load changes nothing now
      buffer.restoring = false
      buffer.settled_empty = false
      buffer.confirm_since = nil
      buffer.missing_path = nil
      buffer.checking_from, buffer.checking_load = nil, nil
      if not playable then
        set_buffer_file_param(slot, _path.audio)
        buffer.seconds = 0  -- the engine reports 0 s until the take completes
        -- an armed take's timer starts at its recording report
        if not armed then start_take_timer(slot, seconds) end
      end
    end
    S.lib.buffers.display_changed()
  end

  -- What the slot is recording: nil when idle, else
  -- {number, kind = "take" | "playable", phase = "armed" | "recording",
  -- started_at (nil while armed), seconds, loop}
  function M.state(slot)
    if not S.buffers[slot] or not S.buffers[slot].recording then return nil end
    return takes[slot]
  end

  function M.any_recording()
    for slot = 1, NUM_BUFFERS do
      local state = M.state(slot)
      if state and state.phase == "recording" then return true end
    end
    return false
  end

  function M.any_armed()
    for slot = 1, NUM_BUFFERS do
      local state = M.state(slot)
      if state and state.phase == "armed" then return true end
    end
    return false
  end

  -- A recording slot's bufferState report (lib/buffers.lua calls it): a
  -- playable recording keeps its slot loaded once it has a length
  function M.slot_reported(slot, seconds)
    local state = takes[slot]
    if state and state.kind == "playable" and seconds > 0 and not S.buffers[slot].loaded then
      S.buffers[slot].loaded = true
    end
  end

  -- recordState poll: value = ((record number * 4) + state) * NUM_BUFFERS +
  -- slot index; state 0 armed, 1 recording, 2 ended and kept, 3 canceled.
  -- Only the slot's newest recording's reports act, in whatever order they
  -- arrive (records_sent counts them as the engine does).
  local STATE_ARMED, STATE_RECORDING, STATE_ENDED, STATE_CANCELED = 0, 1, 2, 3
  local function record_state_changed(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
      or value ~= math.floor(value) then return end
    local slot = value % NUM_BUFFERS + 1
    local rest = math.floor(value / NUM_BUFFERS)
    local state_code = rest % 4
    local number = math.floor(rest / 4)
    local buffer = S.buffers[slot]
    local take = takes[slot]
    if not buffer or not take or not buffer.recording or number ~= buffer.records_sent or take.number ~= number then
      return
    end
    if state_code == STATE_ARMED then
      if take.phase ~= "recording" then take.phase = "armed" end
    elseif state_code == STATE_RECORDING then
      take.phase = "recording"
      take.started_at = util.time()
      if take.kind == "take" and not S.buffer_record_clocks[slot] and not buffer.finishing then
        start_take_timer(slot, take.seconds)
      end
    elseif state_code == STATE_ENDED then
      if take.kind == "playable" then
        M.cancel_timer(slot)
        takes[slot] = nil
        buffer.recording = false
        buffer.name = "take " .. slot
        buffer.path = scratch_take_path(slot)
        -- the take is the scratch file at the server rate, read from its start
        buffer.start, buffer.sample_rate, buffer.file_seconds = 0, nil, nil
        buffer.loaded = buffer.seconds > 0
        set_buffer_file_param(slot, _path.audio)
        S.lib.waveforms.stale(slot)
      elseif not buffer.finishing then
        M.cancel_timer(slot)
        finish_buffer_take(slot)
      end
    elseif state_code == STATE_CANCELED then
      M.cancel_timer(slot)
      takes[slot] = nil
      buffer.recording = false
      buffer.finishing = false
      buffer.confirm_since = nil
      if take.kind == "take" then
        -- the preparation emptied and zeroed the slot
        buffer.name, buffer.path, buffer.loaded, buffer.seconds = "empty", nil, false, 0
        buffer.settled_empty = false
      end
    end
    S.lib.buffers.display_changed()
  end

  local record_poll = nil
  S.register_start(S.constants.START_ORDER.record_poll, function()
    record_poll = poll.set("recordState", record_state_changed)
    if record_poll then
      record_poll:start()
    else
      print("recordState poll not found")
    end
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.record, function()
    if record_poll then record_poll:stop() end
    takes = {}
  end)

  -- The tests reach finish_buffer_take (and BUFFER_SETTLE, its upvalue) here
  S.finish_buffer_take = finish_buffer_take

  return M
end

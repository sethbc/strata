-- lib/record.lua
-- Recording: record_buffer, the take timers (S.buffer_record_clocks) and
-- how a take settles, moved out of lib/buffers.lua. The slots themselves,
-- the polls' decoding and settle_buffer_slot stay in lib/buffers.lua. The
-- recordBuffer arguments past level are neutral until 3.3's record packages.
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

  -- Record the live input into a slot for record_duration seconds, or, if the
  -- slot is already recording, stop early and keep what was captured. A take
  -- that has ended and waits for the engine (finishing) ignores the press.
  function record_buffer(slot)
    if not S.lib.buffers.valid_buffer_slot(slot) then return end
    local buffer = S.buffers[slot]
    if buffer.finishing then return end
    M.cancel_timer(slot)
    if buffer.recording then
      engine.stopRecord(slot - 1)
      finish_buffer_take(slot)
    else
      -- at most what a slot holds on this tier (the param's range already
      -- ends there; a value set before the range was known never passes it)
      local duration = math.min(params:get("record_duration"), S.performance.buffer_seconds)
      engine.recordBuffer(slot - 1, duration, params:get("record_level"), 0, 0, 0, 0, 0)
      buffer.records_sent = buffer.records_sent + 1
      takes[slot] = {number = buffer.records_sent, kind = "take", phase = "recording", started_at = util.time(),
        seconds = duration, loop = false}
      S.lib.buffers.recording_started(slot)
      set_buffer_file_param(slot, _path.audio)
      buffer.recording = true
      buffer.seconds = 0  -- the engine reports 0 s until the take completes
      buffer.pending_loads = {}  -- a failure reported for an earlier load changes nothing now
      buffer.restoring = false
      buffer.settled_empty = false
      buffer.confirm_since = nil
      buffer.missing_path = nil
      buffer.checking_from, buffer.checking_load = nil, nil
      S.buffer_record_clocks[slot] = clock.run(function()
        clock.sleep(duration)
        S.buffer_record_clocks[slot] = nil
        finish_buffer_take(slot)
        S.lib.buffers.display_changed()
      end)
    end
    S.lib.buffers.display_changed()
  end

  -- What the slot is recording: nil when idle, else a take
  -- (number, kind "take", phase "recording", started_at, seconds, loop false)
  function M.state(slot)
    if not S.buffers[slot] or not S.buffers[slot].recording then return nil end
    return takes[slot]
  end

  -- A recording slot's bufferState report (lib/buffers.lua calls it).
  -- Neutral until 3.3's record packages
  function M.slot_reported(_, _)
  end

  -- The tests reach finish_buffer_take (and BUFFER_SETTLE, its upvalue) here
  S.finish_buffer_take = finish_buffer_take

  return M
end

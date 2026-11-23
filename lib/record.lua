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

  -- per slot: the id of the slot's one clock (the tests and the cleanup
  -- order test read it as an id, plan ruling 10), a clock helper's (#870)
  -- in one of three roles: "take" (the timer that ends a replace take),
  -- "fallback" (a take's settle, or a playable recording's end, with no
  -- report from the engine) or "notice" (lib/buffers.lua's notice for a
  -- long load's check, start_check_notice). A load, clear, recording or
  -- cleanup ends whichever runs
  S.buffer_record_clocks = {}
  -- per slot: that clock's handle and role, beside its id
  local slot_clocks = {}
  -- per slot, while a take records: what S.lib.record.state reports
  local takes = {}
  -- per slot: the clock's tempo at the start of its newest recording made
  -- with record_sync on (3.7: the take's tempo once it ends), else nil
  local synced_tempos = {}

  -- The one place the slot's clock is set: its handle and role, and its id
  -- in S.buffer_record_clocks (nil handle: none)
  local function set_slot_clock(slot, handle, role)
    slot_clocks[slot] = handle and {handle = handle, role = role} or nil
    S.buffer_record_clocks[slot] = handle and handle.id or nil
  end

  -- The role of the slot's clock ("take", "fallback" or "notice"), or nil
  -- when none runs
  function M.clock_role(slot)
    local entry = slot_clocks[slot]
    return entry and entry.role or nil
  end

  -- End the slot's take timer, fallback or check notice, if any: stopped
  -- through the clock helper, never canceled while its wake may be posted
  -- (a report that ends a take arrives about when its timer runs out)
  function M.cancel_timer(slot)
    local entry = slot_clocks[slot]
    if entry then S.lib.clocks.stop(entry.handle) end
    set_slot_clock(slot, nil)
  end

  -- The slot's take has ended or been superseded (lib/buffers.lua's
  -- settle of a replace take, a load, a clear): its clock ends and its
  -- record goes (#903; a dub's end and a cancel forget it here: before
  -- 3.9 a superseded take's stayed, hidden only by M.state's gate)
  function M.end_take(slot)
    M.cancel_timer(slot)
    takes[slot] = nil
  end

  -- Run the slot's clock in `role`: the one it held ends first; `seconds`
  -- later it is forgotten and action() runs
  function M.run_slot_clock(slot, role, seconds, action)
    M.cancel_timer(slot)
    local handle = S.lib.clocks.run(function(handle)
      if not handle.sleep(seconds) then return end
      local entry = slot_clocks[slot]
      if not entry or entry.handle ~= handle then return end
      set_slot_clock(slot, nil)
      action()
    end)
    set_slot_clock(slot, handle, role)
  end

  -- End every slot's clock at once (the cleanup step of lib/buffers.lua's
  -- polls: norns ends every clock anyway)
  function M.stop_all()
    for slot = 1, NUM_BUFFERS do
      local entry = slot_clocks[slot]
      if entry then S.lib.clocks.cancel(entry.handle) end
      set_slot_clock(slot, nil)
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
    M.run_slot_clock(slot, "fallback", BUFFER_SETTLE.fallback_seconds, function()
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
  -- (design 1.6); 0 without sync. At the tempo the clock runs from now on,
  -- also right after a change (beat_seconds_now, #567)
  local function sync_delay()
    local sync = params:get("record_sync")
    if sync == 1 then return 0 end
    local quantum = sync == 2 and 1 or S.constants.RECORD_SYNC.beats_per_bar
    local beat_seconds = S.lib.params_setup.beat_seconds_now()
    local now = clock.get_beats()
    local lead = S.constants.RECORD_SYNC.lead_seconds / beat_seconds
    local target = math.ceil((now + lead) / quantum) * quantum
    return (target - now) * beat_seconds
  end

  -- The length the next recording would have, at the tempo the clock runs
  -- from now on (beat_seconds_now: a tempo just set counts at once, #567):
  -- {seconds, beats, capped}. Sync off: record_duration (beats nil). Sync on:
  -- record_beats beats; when they need more than a slot holds, the whole
  -- beats that fit (capped true), so a loop recorded this way still wraps
  -- on the beat, or the whole slot when not one beat fits (beats 0).
  -- record_buffer sends its seconds and BUFFER's len field shows its beats:
  -- the one place the cap is worked out (#321)
  function M.take_length()
    local slot_seconds = S.performance.buffer_seconds
    if params:get("record_sync") == 1 then
      -- at most what a slot holds on this tier (the param's range already
      -- ends there; a value set before the range was known never passes it)
      return {seconds = math.min(params:get("record_duration"), slot_seconds)}
    end
    local beat_seconds = S.lib.params_setup.beat_seconds_now()
    local beats = params:get("record_beats")
    local fit = math.floor(slot_seconds / beat_seconds + 1e-9)
    -- fit beats can pass the slot by a rounding error when a slot is a
    -- whole number of beats: the seconds never do
    if beats <= fit then
      return {seconds = math.min(beats * beat_seconds, slot_seconds), beats = beats, capped = false}
    end
    if fit < 1 then return {seconds = slot_seconds, beats = 0, capped = true} end
    return {seconds = math.min(fit * beat_seconds, slot_seconds), beats = fit, capped = true}
  end

  -- The engine stopped playing a replace take's slot's old audio, so the
  -- slot is unbound, once (3.7: the binding names the audio that plays): at
  -- the send for a take with no delay (the engine empties its slot at once,
  -- a threshold's wait included), else at the slot's first 0 s report (the
  -- engine empties a synced take's slot just before its start) or at its
  -- "recording" report, whichever comes first. Through a synced take's arm
  -- wait the old audio plays on with its settings
  local function take_started(slot, take)
    if take.kind ~= "take" or take.unbound then return end
    take.unbound = true
    S.lib.samples.unbind(slot)
  end

  local start_playable_fallback

  -- Start the take timer: `seconds` later the take finishes, or, for a
  -- playable recording with a length (loop off), its fallback starts
  -- (#904: the engine ends it there, and its "ended" report may be lost)
  local function start_take_timer(slot, seconds)
    local take = takes[slot]
    M.run_slot_clock(slot, "take", seconds, function()
      if take and take.kind == "playable" then
        if takes[slot] == take then start_playable_fallback(slot, take) end
        return
      end
      finish_buffer_take(slot)
      S.lib.buffers.display_changed()
    end)
  end

  -- A playable recording's end, from its "ended" report or its fallback:
  -- the slot is take <n> on the scratch path, or on none when the take is
  -- unsaved (take_unsaved: its write failed before this, or an armed one's
  -- fallback set it), as confirm_buffer_audio settles a replace take: it
  -- plays, is not restored and can be saved. Loaded when its last known
  -- length is above 0
  local function end_playable(slot)
    local buffer = S.buffers[slot]
    M.cancel_timer(slot)
    takes[slot] = nil
    buffer.recording = false
    buffer.name = "take " .. slot
    buffer.path = (not buffer.take_unsaved) and scratch_take_path(slot) or nil
    -- the take is the scratch file at the server rate, read from its start
    buffer.start, buffer.sent_start, buffer.sample_rate, buffer.file_seconds = 0, 0, nil, nil
    buffer.loaded = buffer.seconds > 0
    set_buffer_file_param(slot, _path.audio)
    S.lib.waveforms.stale(slot)
    -- 3.7: a take now, its settings a copy of the file's it was
    -- recorded over (a synced one's tempo the clock's at its start)
    S.lib.samples.take_from_file(slot, M.synced_tempo(slot))
    S.lib.samples.bind(slot)
  end

  -- A recording's cancel, from its "canceled" report
  local function cancel_recording(slot, take)
    local buffer = S.buffers[slot]
    M.cancel_timer(slot)
    takes[slot] = nil
    buffer.recording = false
    buffer.finishing = false
    buffer.confirm_since = nil
    if take.kind == "take" then
      -- empty, unless the engine's next bufferState report (sent right
      -- after this one) shows audio: the take had not prepared the slot,
      -- and buffer_state_changed puts back what it replaced
      buffer.name, buffer.path, buffer.loaded, buffer.seconds = "empty", nil, false, 0
      buffer.settled_empty = false
      buffer.kept_state = take.previous
    else
      -- a playable recording keeps the slot's audio, but the engine set
      -- its gain to 1 at the command: its peaks are read again, and a
      -- normalized slot's gain goes back (3.7, design §4.4)
      S.lib.waveforms.stale(slot)
    end
  end

  -- A playable recording's fallback (#904), started at K3 or when its
  -- length has run out (a loop has none: K3 only):
  -- BUFFER_SETTLE.fallback_seconds later, with no "ended" or "canceled"
  -- report, it ends as a recording that ran, from the last known length,
  -- so K3 is never answered by stopRecord alone for good. One stopped
  -- while still armed is taken as recorded into too, never left named for
  -- a file whose audio may have changed (Lua cannot know whether it
  -- started: a synced one records at its beat while the poll is missing),
  -- but as an unsaved take, on no path: a cancel writes no take, and the
  -- scratch file may hold an older one, which a restore would bring back
  -- under this name. Either way the cost is at most a save. A K3 while
  -- the fallback waits leaves it as it is
  start_playable_fallback = function(slot, take)
    if M.clock_role(slot) == "fallback" then return end
    M.run_slot_clock(slot, "fallback", BUFFER_SETTLE.fallback_seconds, function()
      if takes[slot] ~= take or not S.buffers[slot].recording then return end
      if take.phase == "armed" then S.buffers[slot].take_unsaved = true end
      end_playable(slot)
      S.lib.buffers.display_changed()
    end)
  end

  -- Record into a slot with the record params, or, if the slot is armed or
  -- recording, stop (K3: a recording keeps what it captured, an armed one is
  -- canceled). A replace take that has ended and waits for the engine
  -- (finishing) ignores the press.
  function record_buffer(slot)
    slot = S.lib.buffers.slot_index(slot)  -- a whole number from 1 to NUM_BUFFERS (#402)
    if not slot then return end
    local buffer = S.buffers[slot]
    if buffer.finishing then return end
    if buffer.recording then
      engine.stopRecord(slot - 1)
      -- a playable recording ends with the engine's "ended" report (or its
      -- fallback, #904); a take settles from the engine's seconds (or its
      -- fallback)
      if takes[slot] and takes[slot].kind == "take" then
        M.cancel_timer(slot)
        finish_buffer_take(slot)
      elseif takes[slot] then
        start_playable_fallback(slot, takes[slot])
      end
    else
      local feedback = params:get("record_feedback") / 100
      local loop = params:get("record_loop") == 2
      -- a playable recording keeps the slot playing; one into a slot at
      -- another sample rate is a replace take (the engine decides the same)
      local playable = feedback > 0 or loop
      -- While a load awaits the engine, what the slot will hold is not known:
      -- the recording would supersede the load, and the engine would judge
      -- the take by what the slot held at that moment. A replace take is the
      -- same take either way; a playable one waits (K3 again once the slot
      -- shows its length) (#455)
      if playable and buffer.confirm_since ~= nil then
        buffer_page_flash("buf " .. slot .. " loading")
        return
      end
      M.cancel_timer(slot)
      local threshold = 0
      local threshold_index = params:get("record_threshold")
      if threshold_index > 1 then threshold = 10 ^ (THRESHOLD_DB[threshold_index - 1] / 20) end
      local delay = sync_delay()
      -- what BUFFER's dur or len field shows (a capped synced take is the
      -- whole beats that fit, #321)
      local seconds = M.take_length().seconds
      -- (the rate of a file the engine confirmed: a slot that shows no audio
      -- is empty to the engine, whatever file was last named for it)
      local rate = buffer.loaded and buffer.sample_rate or nil
      if playable and rate and rate ~= S.constants.NORNS_SAMPLE_RATE then
        playable = false
        loop = false  -- a replace take ends at its length
        buffer_page_flash("buf " .. slot .. ": replaced (rate)")
      end
      -- what a replace take replaces, put back if it is canceled before the
      -- engine prepares its slot (taken before anything below changes it)
      local previous = (not playable) and S.lib.buffers.state_before_take(slot) or nil
      -- last, the wall clock modulo 1000 s at the send (a float32 keeps
      -- about 61 us there): the engine starts a synced take delay after it,
      -- however long the command waits for a busy sclang (#565)
      engine.recordBuffer(slot - 1, seconds, params:get("record_level"), feedback, params:get("record_source") - 1,
        threshold, loop and 1 or 0, delay, util.time() % 1000)
      synced_tempos[slot] = params:get("record_sync") > 1
        and S.lib.samples.SAMPLES.seconds_per_minute / S.lib.params_setup.beat_seconds_now() or nil
      buffer.records_sent = buffer.records_sent + 1
      local armed = delay > 0 or threshold > 0
      takes[slot] = {number = buffer.records_sent, kind = playable and "playable" or "take",
        phase = armed and "armed" or "recording", started_at = (not armed) and util.time() or nil,
        seconds = seconds, loop = loop, previous = previous}
      S.lib.buffers.recording_started(slot, playable)
      buffer.recording = true
      if not playable and delay <= 0 then take_started(slot, takes[slot]) end
      buffer.pending_loads = {}  -- a failure reported for an earlier load changes nothing now
      buffer.restoring = false
      buffer.settled_empty = false
      buffer.kept_state = nil
      buffer.confirm_since = nil
      buffer.missing_path = nil
      buffer.checking_from, buffer.checking_load = nil, nil
      if not playable then
        set_buffer_file_param(slot, _path.audio)
        -- the engine reports 0 s until the take completes; a synced take's
        -- slot keeps its length until the engine prepares it and says so
        if delay <= 0 then buffer.seconds = 0 end
        -- an armed take's timer starts at its recording report
        if not armed then start_take_timer(slot, seconds) end
      elseif not loop and not armed then
        -- a dub's length: its fallback starts where the engine ends it (#904)
        start_take_timer(slot, seconds)
      end
    end
    S.lib.buffers.display_changed()
  end

  -- The clock's tempo at the start of the slot's newest recording when it
  -- was made with record_sync on, once: the take that settles takes it
  -- (lib/buffers.lua's confirm_buffer_audio, the "ended" report above)
  function M.synced_tempo(slot)
    local tempo = synced_tempos[slot]
    synced_tempos[slot] = nil
    return tempo
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
  -- playable recording keeps its slot loaded once it has a length, and a
  -- dub into a slot with no file (an empty one) is take <n> from then on,
  -- its path coming at "ended": a failed load during it puts back a named
  -- slot, never a loaded one named "empty" (#400). True when it changed
  -- the slot
  function M.slot_reported(slot, seconds)
    local state = takes[slot]
    local buffer = S.buffers[slot]
    -- a replace take's slot emptied: its old audio no longer plays
    if state and state.kind == "take" and seconds <= 0 then take_started(slot, state) end
    if not (state and state.kind == "playable" and seconds > 0 and not buffer.loaded) then return false end
    buffer.loaded = true
    if buffer.path == nil then buffer.name = "take " .. slot end
    return true
  end

  -- recordState poll: value = ((record number * 4) + state) * NUM_BUFFERS +
  -- slot index; state 0 armed, 1 recording, 2 ended and kept, 3 canceled.
  -- Only the slot's newest recording's reports act, in whatever order they
  -- arrive (records_sent counts them as the engine does). matron hands every
  -- poll value over as a float, so the slot is floored: on Lua 5.3 a float
  -- slot names the take "take 3.0" and its file param "buf3.0_file" (#300).
  local STATE_ARMED, STATE_RECORDING, STATE_ENDED, STATE_CANCELED = 0, 1, 2, 3
  local function record_state_changed(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
      or value ~= math.floor(value) then return end
    local slot = math.floor(value % NUM_BUFFERS) + 1
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
      take_started(slot, take)
      -- the timer of a take, or of a dub with a length (#904), unless one
      -- runs or the recording has ended (finishing, or a dub's fallback):
      -- whatever else the slot's clock is (#870)
      local role = M.clock_role(slot)
      if (take.kind == "take" or not take.loop) and role ~= "take" and role ~= "fallback"
        and not buffer.finishing then
        start_take_timer(slot, take.seconds)
      end
    elseif state_code == STATE_ENDED then
      if take.kind == "playable" then
        end_playable(slot)
      else
        if not buffer.finishing then
          M.cancel_timer(slot)
          finish_buffer_take(slot)
        end
        -- the engine reports a take's length before "ended": a length known
        -- by now is the take's, so it settles at once rather than at the
        -- next periodic report (#457)
        if buffer.seconds > 0 then settle_buffer_slot(slot) end
      end
    elseif state_code == STATE_CANCELED then
      cancel_recording(slot, take)
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
  -- (a running take's record stays: no take ends at cleanup, the engine
  -- finishes or frees it, and the slot still records, #903)
  S.register_cleanup(S.constants.CLEANUP_ORDER.record, function()
    if record_poll then record_poll:stop() end
    synced_tempos = {}
  end)

  -- The tests reach finish_buffer_take (and BUFFER_SETTLE, its upvalue) here
  S.finish_buffer_take = finish_buffer_take

  return M
end

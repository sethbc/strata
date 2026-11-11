-- lib/buffers.lua
-- The sample buffers: what each slot holds (S.buffers), loading, clearing
-- and saving them (recording is lib/record.lua's), the engine's bufferState, bufferLoadFailed and
-- bufferSaveResult polls (S.buffer_polls; init starts them), and the buffer paths kept in
-- buffers.data. The functions that were global stay global;
-- valid_buffer_slot (for lib/grid/layout_256.lua), buffer_state_changed
-- (the bufferState poll's handler, which init sets), BUFFER_SETTLE (shared
-- with lib/record.lua), display_changed and recording_started (a hook
-- lib/record.lua calls) are fields of this module's table (S.lib.buffers).
-- Registers two cleanup steps (saving the buffer paths; the polls and
-- recording timers).

-- At the start of a line (outside the constructor): a test finds the
-- stride by matching this line in the script's sources
local BUFFER_STATE_STRIDE = 1000  -- bufferState value = slot index * 1000 + valid seconds (engine bufferStateStride)

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local NUM_VOICES = S.constants.NUM_VOICES
  local BUFFER_DATA_VERSION = S.constants.BUFFER_DATA_VERSION

  -- Sample buffers. The engine holds the audio; Lua tracks what each slot
  -- holds for the screen and scenes. path is the loaded file, or the scratch
  -- take the engine writes when a recording completes (or stops early).
  -- The bufferState poll settles what the slot holds: a take is loaded only
  -- once the engine reports its seconds (recording stays set, finishing
  -- marks it, until then), and a file load, shown at once, stays loaded only
  -- if the engine reports audio. confirm_since is the util.time() of the
  -- change awaiting that report (nil = settled); restoring marks a load from
  -- load_buffers_from_disk until it settles, with or without audio;
  -- settled_empty is "take", "load" or "restore" when that settled without
  -- audio (a later report of audio adopts it: a slow take or file read, and a
  -- restore then counts in buffers_restored), else false;
  -- missing_path is a remembered file that was not found on start (kept in
  -- buffers.data). records_sent counts the slot's recordBuffer commands
  -- (lib/record.lua). loads_sent counts the slot's loadBuffer commands (the
  -- engine counts them too and names one in its bufferLoadFailed report);
  -- pending_loads holds the newest of them, oldest first, each with the state
  -- it replaced, so a failed load can be undone (buffer_load_failed).
  -- saves_sent counts the slot's saveBuffer commands (the engine counts them
  -- too and names one in its bufferSaveResult report); pending_saves holds
  -- the newest of them, oldest first, each with its path, until the engine
  -- reports how it ended (buffer_save_result).
  -- checking_from is the length shown before a load the engine checks in a
  -- routine first (a long file on a high tier), while it checks (nil
  -- otherwise): until a report differs from it, the poll leaves the load
  -- unsettled and the BUFFER page shows "..." for the length. checking_load
  -- is that load's number; if no differing report comes within
  -- BUFFER_SETTLE.check_fallback_seconds, the slot goes back to the state
  -- the load replaced (start_check_fallback).
  -- kept_state is what a canceled replace take had replaced, from its
  -- "canceled" report until the engine's next report of the slot's length:
  -- audio means the take had not prepared the slot, which is as it was, so
  -- buffer_state_changed puts it back; 0 s drops it (nil otherwise).
  S.buffers = {}
  for slot = 1, NUM_BUFFERS do
    S.buffers[slot] = {name = "empty", loaded = false, recording = false, finishing = false, restoring = false,
      settled_empty = false, seconds = 0, path = nil, confirm_since = nil, missing_path = nil,
      loads_sent = 0, pending_loads = {}, saves_sent = 0, pending_saves = {}, records_sent = 0,
      checking_from = nil, checking_load = nil, start = 0, sent_start = 0, sample_rate = nil, file_seconds = nil,
      kept_state = nil}
  end
  -- the engine's bufferState, bufferLoadFailed and bufferSaveResult polls (nil if missing)
  S.buffer_polls = {state = nil, load_failed = nil, save_result = nil}
  -- confirm_seconds: a report of 0 s settles a take or load only this long
  -- after the change (the periodic poll can carry a value read before the
  -- engine finished: the recording timer ends just before the engine's take
  -- completes). fallback_seconds: a finishing take with no report at all
  -- (no bufferState poll) settles this long after it ended, from the slot's
  -- last known seconds. tracked_loads: a slot's newest loads a bufferLoadFailed
  -- report can still undo (a report arrives within a fade wait and a read, so
  -- more than one is only ever pending for loads sent back to back).
  -- tracked_saves: a slot's newest saves whose bufferSaveResult report is
  -- still awaited. On the high tier a 300 s save takes seconds, so saves can
  -- overlap; keeping only the newest 4 is still safe: the flash depends only
  -- on saves_sent, and dropping an older entry only loses that save's console
  -- line.
  -- server_rate: the engine checks a file in a routine when it would read
  -- more than its standard slot length at the server's rate
  -- (loadCheckAtOnceFrames, lib/engine/StrataBuffers.sc). Lua cannot learn
  -- that rate: performance_active.data and the bufferState poll carry
  -- seconds only, never a rate. norns runs its audio server (JACK and
  -- scsynth) at 48 kHz, so this is 48000; a misjudged file near the edge
  -- only shows "..." until the engine's first report, or loads as before.
  -- check_fallback_seconds: a long file's load the engine is checking goes
  -- back to the state it replaced when no report ends the check this long
  -- after it was sent (no bufferState poll, or a check that never ends). A
  -- 300 s load (check and read) takes 0.4-0.65 s on a desktop
  -- (docs/notes/engine/files.md); 30 s leaves a Pi's slower FLAC decoding
  -- about 45 times that.
  -- start: seconds into the slot's file the load began at (0 for a new file;
  -- sent with every load of the slot, kept in buffers.data; set_start moves it
  -- ahead of its reload); sent_start: the start of the load last sent, what a
  -- failed load puts back (#245); sample_rate and
  -- file_seconds: the loaded file's rate and length from audio.file_info, nil
  -- for a take, a clear or a file it cannot read (set_start
  -- clamps the start to what the file leaves after a slot's length)
  local BUFFER_SETTLE = {confirm_seconds = 1, fallback_seconds = 5, tracked_loads = 4, tracked_saves = 4,
    server_rate = 48000, check_fallback_seconds = 30}
  S.buffers_restored = 0  -- restored slots the engine confirmed holding audio (SETUP page)
  local buffer_audio_dir = _path.audio .. "strata/"
  local buffer_scratch_dir = buffer_audio_dir .. "scratch/"  -- engine scratchDir

  local function valid_buffer_slot(slot)
    return slot >= 1 and slot <= NUM_BUFFERS
  end

  -- Buffer state is shown on the BUFFER page and the 256 grid's page 4, and
  -- what the slots remember goes to buffers.data when it changed (remember,
  -- set with the disk functions further down)
  local remember = function() end
  local function buffer_display_changed()
    request_redraw()
    grid_redraw()
    remember()
  end

  -- lib/record.lua owns the take timers (S.buffer_record_clocks)
  local function cancel_buffer_recording_timer(slot)
    S.lib.record.cancel_timer(slot)
  end

  -- The engine writes each completed (or early-stopped) take here,
  -- overwriting the slot's previous take
  function scratch_take_path(slot)
    return buffer_scratch_dir .. "buf" .. slot .. ".wav"
  end

  -- A take or load in the slot holds audio: loaded (a take named take <n>,
  -- its path the scratch take; a load keeps its name), and a restored slot
  -- (restoring, or a restore that settled empty and is adopted now) counts
  -- in buffers_restored
  function confirm_buffer_audio(slot, is_take)
    local buffer = S.buffers[slot]
    local restored = buffer.restoring or buffer.settled_empty == "restore"
    buffer.loaded = true
    buffer.settled_empty = false
    buffer.restoring = false
    if is_take then
      buffer.name = "take " .. slot
      buffer.path = scratch_take_path(slot)
    end
    if restored then S.buffers_restored = S.buffers_restored + 1 end
  end

  -- Settle a take or load awaiting the engine (confirm_since set) from the
  -- slot's seconds (confirm_buffer_audio). Without audio a take leaves the slot
  -- empty and a load is not loaded (keeping its name); settled_empty records
  -- which ("restore" for a restore), so a later report of audio still adopts
  -- it, and restoring clears: the slot has settled. Cancels the finishing
  -- fallback.
  function settle_buffer_slot(slot)
    local buffer = S.buffers[slot]
    local is_take = buffer.finishing
    buffer.confirm_since = nil
    if is_take then
      cancel_buffer_recording_timer(slot)
      buffer.finishing = false
      buffer.recording = false
    end
    if buffer.seconds > 0 then
      confirm_buffer_audio(slot, is_take)
    else
      buffer.loaded = false
      buffer.settled_empty = is_take and "take" or (buffer.restoring and "restore" or "load")
      buffer.restoring = false
      if is_take then
        buffer.name = "empty"
        buffer.path = nil
      end
    end
  end

  -- A usable sound file path: not empty, not norns' "-" (no file chosen) and
  -- not a directory (the file param's starting folder)
  local function is_sound_file_path(path)
    return type(path) == "string" and path ~= "" and path ~= "-" and path:sub(-1) ~= "/"
  end

  -- Show path in the slot's buf<n>_file param without running its action.
  -- norns' file param runs the action only when the path changes, so a
  -- record or clear puts it back at its starting folder (_path.audio, which
  -- loads nothing): picking the same file again then loads it.
  function set_buffer_file_param(slot, path)
    params:set("buf" .. slot .. "_file", path, true)
  end

  -- An empty slot's shown state and file param, for buffer_load_failed.
  -- settled_empty is "take" after a canceled recording whose take may have
  -- completed (a later report of audio adopts it), else false.
  function empty_buffer_state(settled_empty)
    return {name = "empty", loaded = false, restoring = false, settled_empty = settled_empty,
      confirm_since = nil, path = nil, missing_path = nil, file_param = _path.audio, checking_from = nil,
      checking_load = nil, start = 0, sent_start = 0, sample_rate = nil, file_seconds = nil}
  end

  -- What a load replaces in the slot, for buffer_load_failed to put back: the
  -- shown state and the buf<n>_file param. A replace take recording (or
  -- waiting for the engine) has nothing to put back: the engine cancels it
  -- when the load fails and the take had emptied the slot, so the slot
  -- becomes empty, settled_empty "take" so that a take that had already
  -- completed is still adopted from the engine's report. A replace take
  -- still armed (also one K3 has stopped, finishing until its "canceled"
  -- report: it never recorded) may not have prepared its slot (a synced take
  -- keeps it playing until just before its start), so the state is decided
  -- when the failure is reported, by the length the engine sent after
  -- "canceled" (resolve_previous): {after_cancel = true, kept = what the
  -- take replaced}.
  -- A playable recording (S.lib.record.state(slot).kind == "playable") keeps
  -- the slot's audio, so a failed load during one restores the slot as it was.
  function buffer_state_before_load(slot)
    local buffer = S.buffers[slot]
    local record_state = S.lib.record.state(slot)
    local playable = record_state ~= nil and record_state.kind == "playable"
    if (buffer.recording or buffer.finishing) and not playable then
      if record_state and record_state.phase == "armed" and record_state.previous then
        return {after_cancel = true, kept = record_state.previous}
      end
      return empty_buffer_state("take")
    end
    return M.shown_state(slot)
  end

  -- The slot's shown state and file param, as apply_buffer_state takes it
  function M.shown_state(slot)
    local buffer = S.buffers[slot]
    return {name = buffer.name, loaded = buffer.loaded, restoring = buffer.restoring,
      settled_empty = buffer.settled_empty, confirm_since = buffer.confirm_since, path = buffer.path,
      missing_path = buffer.missing_path, file_param = params:get("buf" .. slot .. "_file"),
      checking_from = buffer.checking_from, checking_load = buffer.checking_load,
      start = buffer.sent_start, sample_rate = buffer.sample_rate, file_seconds = buffer.file_seconds}
  end

  -- What a failed load puts back, once the engine has said how the load left
  -- the slot: a state from buffer_state_before_load as it is, or, for a load
  -- that canceled a replace take still armed, what the take had replaced
  -- when the slot still reads audio (the take had not prepared it), else the
  -- empty slot a prepared take leaves
  local function resolve_previous(slot, previous)
    if not previous.after_cancel then return previous end
    if S.buffers[slot].seconds > 0 then return previous.kept end
    return empty_buffer_state("take")
  end

  -- What a replace take replaces, put back if it is canceled before the
  -- engine prepares its slot: the shown state, or, while the engine still
  -- checks loads (which the take supersedes, every one, so none arrives),
  -- what the earliest of them replaced (an empty slot if one is no longer
  -- tracked). Each load's state names an earlier load, so this ends
  function M.state_before_take(slot)
    local buffer = S.buffers[slot]
    local state = M.shown_state(slot)
    while state.checking_load do
      local replaced = nil
      for _, load in ipairs(buffer.pending_loads) do
        if load.number == state.checking_load then replaced = load.previous end
      end
      if not replaced then return empty_buffer_state(false) end
      state = resolve_previous(slot, replaced)
    end
    return state
  end

  -- Give the slot a state from buffer_state_before_load or
  -- empty_buffer_state (a failed load, or a check that never ended),
  -- including its file param, silently
  local function apply_buffer_state(slot, state)
    local buffer = S.buffers[slot]
    buffer.name = state.name
    buffer.loaded = state.loaded
    buffer.restoring = state.restoring
    buffer.settled_empty = state.settled_empty
    buffer.confirm_since = state.confirm_since
    buffer.path = state.path
    buffer.missing_path = state.missing_path
    buffer.checking_from = state.checking_from
    buffer.checking_load = state.checking_load
    buffer.start = state.start or 0
    buffer.sent_start = buffer.start
    buffer.sample_rate, buffer.file_seconds = state.sample_rate, state.file_seconds
    set_buffer_file_param(slot, state.file_param)
  end

  -- The fallback for a load the engine is checking (checking_load =
  -- load_number): if no report has ended the check after
  -- check_fallback_seconds, the slot goes back to the state the load
  -- replaced, so its row never stays at "..." (that load is then forgotten:
  -- a later report of its failure changes nothing). It runs in
  -- buffer_record_clocks[slot], which a load, clear, recording and cleanup
  -- cancel; the end of the check cancels it too
  local function start_check_fallback(slot, load_number)
    cancel_buffer_recording_timer(slot)
    S.buffer_record_clocks[slot] = clock.run(function()
      clock.sleep(BUFFER_SETTLE.check_fallback_seconds)
      S.buffer_record_clocks[slot] = nil
      local buffer = S.buffers[slot]
      if buffer.checking_from == nil or buffer.checking_load ~= load_number then return end
      local previous = empty_buffer_state(false)
      for index, load in ipairs(buffer.pending_loads) do
        if load.number == load_number then
          previous = resolve_previous(slot, table.remove(buffer.pending_loads, index).previous)
          break
        end
      end
      apply_buffer_state(slot, previous)
      -- the state put back may be an earlier check, whose fallback this load canceled
      buffer.checking_from, buffer.checking_load = nil, nil
      print("buffer " .. slot .. ": no length from the engine " .. BUFFER_SETTLE.check_fallback_seconds
        .. " s after loading " .. tostring(buffer.path or "a file") .. "; showing what it held before")
      buffer_display_changed()
    end)
  end

  -- Whether the engine checks the file in a routine before the load takes
  -- effect (loadSlot): on a tier whose slots hold more than the standard
  -- length, a file of more frames than that at the server rate, counting
  -- only what the slot reads (at most buffer_seconds at the file's rate and
  -- at the server's). norns' audio.file_info gives its frames and rate; a
  -- file it cannot open (0 frames) is rejected at once, unchecked
  local function checked_before_load(path)
    local standard_seconds = S.constants.STANDARD_BUFFER_SECONDS
    local seconds = S.performance.buffer_seconds
    if seconds <= standard_seconds or not (audio and audio.file_info) then return false end
    local inspected, _, frames, rate = pcall(audio.file_info, path)
    if not inspected or type(frames) ~= "number" or type(rate) ~= "number" or rate <= 0 then return false end
    local read = math.min(frames, rate * seconds, BUFFER_SETTLE.server_rate * seconds)
    return read > BUFFER_SETTLE.server_rate * standard_seconds
  end

  -- A file's sample rate and length in seconds (audio.file_info), or nil, nil
  -- for a file it cannot open
  local function file_length(path)
    if not (audio and audio.file_info) then return nil, nil end
    local inspected, _, frames, rate = pcall(audio.file_info, path)
    if not inspected or type(frames) ~= "number" or type(rate) ~= "number" or frames <= 0 or rate <= 0 then
      return nil, nil
    end
    return rate, frames / rate
  end

  -- per slot: the clock that reloads the slot's file at a new start
  local start_reload_clocks = {}
  M.start_reload_clocks = start_reload_clocks  -- the tests find the clocks here

  local function cancel_start_reload(slot)
    if start_reload_clocks[slot] then
      clock.cancel(start_reload_clocks[slot])
      start_reload_clocks[slot] = nil
    end
  end

  -- Load path into the slot from start seconds into the file (default 0)
  function load_buffer(slot, path, start)
    if not valid_buffer_slot(slot) or not is_sound_file_path(path) then return end
    start = (type(start) == "number" and start == start and start > 0 and start < math.huge) and start or 0
    local buffer = S.buffers[slot]
    -- remembered (with what it replaces) until a clear or recording, or
    -- tracked_loads newer loads, in case the engine reports it failed
    buffer.loads_sent = buffer.loads_sent + 1
    if #buffer.pending_loads >= BUFFER_SETTLE.tracked_loads then table.remove(buffer.pending_loads, 1) end
    table.insert(buffer.pending_loads, {number = buffer.loads_sent, path = path, previous = buffer_state_before_load(slot)})
    -- loading cancels a recording in progress in the engine
    cancel_buffer_recording_timer(slot)
    cancel_start_reload(slot)
    engine.loadBuffer(slot - 1, path, start)
    -- the BUFFER page's file selector and a restore on start load directly
    set_buffer_file_param(slot, path)
    -- a scratch take restored on start keeps its take name
    buffer.name = path == scratch_take_path(slot) and ("take " .. slot) or path:match("[^/]*$")
    -- shown at once; the engine's report settles loaded (buffer_state_changed)
    buffer.loaded = true
    buffer.recording = false
    buffer.finishing = false
    buffer.restoring = false
    buffer.settled_empty = false
    buffer.kept_state = nil
    buffer.confirm_since = util.time()
    buffer.path = path
    buffer.missing_path = nil
    buffer.start, buffer.sent_start = start, start
    buffer.sample_rate, buffer.file_seconds = file_length(path)
    buffer.checking_from = checked_before_load(path) and buffer.seconds or nil
    buffer.checking_load = buffer.checking_from ~= nil and buffer.loads_sent or nil
    if buffer.checking_load then start_check_fallback(slot, buffer.checking_load) end
    buffer_display_changed()
  end

  function clear_buffer(slot)
    if not valid_buffer_slot(slot) then return end
    cancel_buffer_recording_timer(slot)
    cancel_start_reload(slot)
    engine.clearBuffer(slot - 1)
    set_buffer_file_param(slot, _path.audio)
    local buffer = S.buffers[slot]
    buffer.name = "empty"
    buffer.loaded = false
    buffer.recording = false
    buffer.finishing = false
    buffer.restoring = false
    buffer.settled_empty = false
    buffer.kept_state = nil
    buffer.seconds = 0
    buffer.confirm_since = nil
    buffer.path = nil
    buffer.missing_path = nil
    buffer.checking_from, buffer.checking_load = nil, nil
    buffer.start, buffer.sent_start, buffer.sample_rate, buffer.file_seconds = 0, 0, nil, nil
    buffer.pending_loads = {}  -- a failure reported for an earlier load changes nothing now
    buffer_display_changed()
  end

  -- Timestamped stereo WAV in audio/strata/, so it shows in the file browser
  function buffer_save_path(slot)
    return buffer_audio_dir .. os.date("%Y%m%d-%H%M%S") .. "-buf" .. slot .. ".wav"
  end

  -- Count a save of the slot, track it for its bufferSaveResult report and
  -- send it: the one place a saveBuffer leaves, so the two entry points
  -- number their saves alike
  local function send_save(slot, path, start, length, loop)
    local buffer = S.buffers[slot]
    buffer.saves_sent = buffer.saves_sent + 1
    if #buffer.pending_saves >= BUFFER_SETTLE.tracked_saves then table.remove(buffer.pending_saves, 1) end
    table.insert(buffer.pending_saves, {number = buffer.saves_sent, path = path, loop = loop or nil})
    engine.saveBuffer(slot - 1, path, start, length)
  end

  -- Why a save of the slot cannot go: "invalid" (not a slot), "busy" (the slot
  -- records or awaits its take: an armed recording has `recording` set) or
  -- "empty" (the engine reports no length: a load shows at once, and the
  -- engine's report settles whether it holds audio; a replace take reads 0 s).
  -- nil when it can.
  local function save_refusal(slot)
    if not valid_buffer_slot(slot) then return "invalid" end
    local buffer = S.buffers[slot]
    if buffer.recording or buffer.finishing then
      print("buffer " .. slot .. " is recording, nothing to save yet")
      return "busy"
    end
    if buffer.seconds <= 0 then
      print("buffer " .. slot .. " is empty, nothing to save")
      return "empty"
    end
    return nil
  end

  -- Send a save of the slot: true when it was sent, else false and why (see
  -- save_refusal). The engine reports how it ended (bufferSaveResult,
  -- buffer_save_result), so nothing here says it saved: the file is written a
  -- moment later, or not at all (a full disk). Whoever asks (the save param,
  -- the page), no save goes while the slot records.
  function save_buffer(slot)
    local refusal = save_refusal(slot)
    if refusal then return false, refusal end
    util.make_dir(buffer_audio_dir)
    local path = buffer_save_path(slot)
    send_save(slot, path, 0, 1, false)
    print("buffer " .. slot .. " saving to " .. path)
    return true
  end

  -- The loop (start, length: fractions of the slot) a save of the slot's loop
  -- region writes: the selected voice's if it reads the slot, else the
  -- lowest-numbered voice's that does, else the whole slot
  local function loop_region(slot)
    local LOOP = S.lib.loops.LOOP
    local reader = nil
    if voice_buffer_slot(S.selected_voice) == slot then
      reader = S.selected_voice
    else
      for voice_idx = 1, NUM_VOICES do
        if voice_buffer_slot(voice_idx) == slot then
          reader = voice_idx
          break
        end
      end
    end
    if not reader then return 0, 1 end
    local extras = S.voices[reader].extras
    return extras[LOOP.start_key] or 0, extras[LOOP.length_key] or 1
  end

  -- Timestamped stereo WAV of the slot's loop region in audio/strata/: true
  -- when the save was sent (its result flashes "saved buf <n> loop"), else
  -- false and why, as save_buffer says
  function save_buffer_loop(slot)
    local refusal = save_refusal(slot)
    if refusal then return false, refusal end
    local start, length = loop_region(slot)
    start = util.clamp(start, 0, 1)
    length = util.clamp(length, 0, 1 - start)
    util.make_dir(buffer_audio_dir)
    local path = buffer_audio_dir .. os.date("%Y%m%d-%H%M%S") .. "-buf" .. slot .. "-loop.wav"
    send_save(slot, path, start, length, true)
    print("buffer " .. slot .. " saving its loop to " .. path)
    return true
  end

  -- bufferSaveResult poll: how one of the slot's saves ended. value = (save
  -- number * 2 + failed) * NUM_BUFFERS + slot index; the engine and
  -- save_buffer count a slot's saves alike, from 1. failed is 1 when the
  -- engine wrote nothing (the slot was empty by then, the folder could not be
  -- made, the disk filled: a file already at the path stays), 0 when the
  -- file is in place. A save abandoned for a newer write to the same path is
  -- never reported; the newer one is. The console names the file either way;
  -- the BUFFER page flashes the result only for the slot's newest save, so a
  -- late report never corrects a newer save (still writing, or reported
  -- already). A repeated report, or one for a save no longer tracked, finds
  -- nothing. Loads, clears and recordings leave the tracked saves alone: a
  -- report is about the file written, not what the slot holds now.
  function buffer_save_result(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
      or value ~= math.floor(value) then return end
    local slot = math.floor(value % NUM_BUFFERS) + 1
    local save_and_failed = math.floor(value / NUM_BUFFERS)
    local failed = save_and_failed % 2 == 1
    local save_number = math.floor(save_and_failed / 2)
    if not valid_buffer_slot(slot) then return end
    local buffer = S.buffers[slot]
    local found = nil
    for index, save in ipairs(buffer.pending_saves) do
      if save.number == save_number then
        found = index
        break
      end
    end
    if not found then return end
    local save = table.remove(buffer.pending_saves, found)
    if failed then
      print("buffer " .. slot .. ": cannot save " .. save.path .. " (the engine wrote nothing; a file already there is kept)")
    else
      print("buffer " .. slot .. " saved to " .. save.path)
    end
    if save.number == buffer.saves_sent then
      buffer_page_flash(failed and ("buf " .. slot .. " save failed")
        or ("saved buf " .. slot .. (save.loop and " loop" or "")))
    end
  end

  -- bufferState poll: one slot per message, slot index * 1000 + seconds. It
  -- also settles a take or load awaiting the engine (confirm_since set,
  -- settle_buffer_slot), on any report, repeated or not: audio settles it at
  -- once, 0 s only BUFFER_SETTLE.confirm_seconds after the change. A take or
  -- load that settled empty (a periodic 0 before a slow take or file read
  -- completed) is adopted when audio is reported later, as long as nothing
  -- else (load, clear, a new recording) happened in the slot since. A load
  -- the engine is still checking (checking_from) settles nothing until a
  -- report differs from the length shown before it: the 0 s of the load
  -- taking effect (its read then settles as any load's), or, over an empty
  -- slot, its new length.
  local function buffer_state_changed(value)
    local slot_index = math.floor(value / BUFFER_STATE_STRIDE)
    local slot = slot_index + 1
    -- slot index NUM_BUFFERS: the engine's slot length, not a slot (#153)
    if slot_index == NUM_BUFFERS then
      S.lib.performance.engine_slot_seconds(value - slot_index * BUFFER_STATE_STRIDE)
      return
    end
    if not valid_buffer_slot(slot) then return end
    local seconds = value - slot_index * BUFFER_STATE_STRIDE
    local buffer = S.buffers[slot]
    local changed = buffer.seconds ~= seconds
    buffer.seconds = seconds
    local has_audio = seconds > 0
    -- the first report after a replace take was canceled (the engine sends
    -- it right after "canceled") says what the take left: audio means it had
    -- not prepared the slot, which is as it was before the take
    if buffer.kept_state ~= nil then
      local kept = buffer.kept_state
      buffer.kept_state = nil
      if has_audio then
        apply_buffer_state(slot, kept)
        changed = true
      end
    end
    if buffer.recording then S.lib.record.slot_reported(slot, seconds) end
    -- the engine wrote the slot's peaks before reporting its length
    if changed and has_audio then S.lib.waveforms.stale(slot) end
    if buffer.checking_from ~= nil then
      if seconds == buffer.checking_from then
        if changed then request_redraw() end
        return
      end
      buffer.checking_from, buffer.checking_load = nil, nil
      cancel_buffer_recording_timer(slot)  -- the check's fallback
      buffer.confirm_since = util.time()
      changed = true
    end
    -- a take stopped while still armed has recorded nothing: no length
    -- settles it (a synced take's slot still reports its old audio), only
    -- its "canceled" or "recording" report, or the finishing fallback
    local take = buffer.finishing and S.lib.record.state(slot) or nil
    local stopped_armed = take ~= nil and take.phase == "armed"
    if buffer.confirm_since ~= nil and not stopped_armed
      and (has_audio or util.time() - buffer.confirm_since >= BUFFER_SETTLE.confirm_seconds) then
      settle_buffer_slot(slot)
      changed = true
    elseif has_audio and buffer.settled_empty then
      confirm_buffer_audio(slot, buffer.settled_empty == "take")
      changed = true
    end
    -- the periodic poll repeats unchanged values: redraw only on a change
    if not changed then return end
    request_redraw()  -- the BUFFER page shows the seconds, SETUP the restored count
    if S.lib.grid_core.any_page(S.constants.GRID_PAGES.sources) then grid_redraw() end
    remember()  -- a take that settled has its scratch path now
  end

  -- bufferLoadFailed poll: the engine could not use the file of one of the
  -- slot's loads (missing, unreadable, unsupported, empty or damaged). value =
  -- (load number * 2 + emptied) * NUM_BUFFERS + slot index; the engine and
  -- load_buffer count a slot's loads alike, from 1. emptied is 0 when the load
  -- left the slot as it was (canceling a recording in it), 1 when it left it
  -- empty (the server's read failed after the slot was zeroed). The failed
  -- load is undone only while the slot still tracks it (pending_loads): the
  -- newest load gives the slot the state the failed load left (the state it
  -- replaced: name, path, the file param, settled or not, from
  -- buffer_state_before_load; or an empty slot), so the bad path is never
  -- remembered in buffers.data. A load sent after it (before the report
  -- arrived) stays and inherits that state, to put back if it fails too.
  -- Reports can arrive out of load order (a failed server read is reported
  -- after the fade and the read, a missing file at once), and the splice
  -- handles either order. A clear or a new recording forgets every tracked
  -- load, so it wins; a repeated report finds nothing. The BUFFER page
  -- flashes the failure.
  function buffer_load_failed(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
      or value ~= math.floor(value) then return end
    local slot = math.floor(value % NUM_BUFFERS) + 1
    local load_and_emptied = math.floor(value / NUM_BUFFERS)
    local emptied = load_and_emptied % 2 == 1
    local load_number = math.floor(load_and_emptied / 2)
    if not valid_buffer_slot(slot) then return end
    local buffer = S.buffers[slot]
    local pending = buffer.pending_loads
    local found = nil
    for index, load in ipairs(pending) do
      if load.number == load_number then
        found = index
        break
      end
    end
    if not found then return end
    local failed = table.remove(pending, found)
    local left = emptied and empty_buffer_state(false) or resolve_previous(slot, failed.previous)
    if found <= #pending then
      pending[found].previous = left
    else
      -- buffers_restored needs no undo: a restore loads into a slot that is empty at start, so no report of old audio counted it
      apply_buffer_state(slot, left)
      -- an earlier load still being checked: its fallback starts again
      if buffer.checking_load then start_check_fallback(slot, buffer.checking_load) end
    end
    print("buffer " .. slot .. ": cannot load " .. failed.path .. " (missing, unreadable, empty or damaged)"
      .. (emptied and "; the buffer is now empty" or ""))
    buffer_page_flash("buf " .. slot .. " load failed")
    buffer_display_changed()
  end

  -- Buffer disk persistence: buffers.data remembers, per slot, the loaded file
  -- or the scratch take, so buffer-sourced voices and scenes are not silent
  -- after a restart. It holds only paths; the audio stays in its own files.
  -- It is kept in Strata's data folder, beside scenes.data: the folder is
  -- the scenes' scene_data_dir, read at call time (lib/scenes.lua loads
  -- after this module)
  local function buffer_data_file()
    return S.lib.scenes.scene_data_dir .. "buffers.data"
  end
  -- Set when a buffers file could not be loaded and could not be moved aside
  S.buffer_autosave_blocked = false
  -- Set once load_buffers_from_disk has run to its end in this session: a
  -- start that failed before init's restore leaves it false, and cleanup()
  -- then does not overwrite buffers.data with the empty paths (#72)
  S.buffers_loaded = false
  -- What is known of buffers.data in this session (as S.scene_file, for
  -- SETUP's status rows): version, the format of the file as read when
  -- older than BUFFER_DATA_VERSION (nil once a save has replaced it);
  -- problem, nil, "unreadable" or "not saved"; backup, the name an
  -- unreadable file was kept under (nil: still in place); text, the bytes
  -- last written or found unchanged, which remember compares with, so a
  -- report that changes no path or start costs no file read
  S.buffer_file = {version = nil, problem = nil, backup = nil, text = nil}

  -- What buffers.data holds: per slot the loaded file or scratch take (a
  -- remembered file that was missing on start is kept: it may be on a drive
  -- that is mounted again later), "" for none, and the start
  local function remembered_buffers()
    local paths, starts = {}, {}
    for slot = 1, NUM_BUFFERS do
      paths[slot] = S.buffers[slot].path or S.buffers[slot].missing_path or ""
      starts[slot] = S.buffers[slot].start or 0
    end
    return {version = BUFFER_DATA_VERSION, paths = paths, starts = starts}
  end

  -- Write the paths: true and "written" or "unchanged", or false and why
  -- (the file is then as it was, whole). As the scenes' save: a checked
  -- .part renamed over buffers.data (S.lib.data_files.write, #301), and a
  -- file of an older format first kept as buffers.data.v<n> (#467)
  function save_buffers_to_disk()
    local data_files = S.lib.data_files
    if util.file_exists(S.lib.scenes.scene_data_dir) == false then
      util.make_dir(S.lib.scenes.scene_data_dir)
    end
    local state = S.buffer_file
    local value = remembered_buffers()
    local saved, detail = true, nil
    if state.version then
      saved, detail = data_files.keep_copy(buffer_data_file(), ".v" .. state.version)
      if detail == "copied" then print("buffers file of format " .. state.version .. " kept as " .. saved) end
    end
    if saved then saved, detail = data_files.write(buffer_data_file(), value) end
    if not saved then
      state.problem = "not saved"
      print("error: buffer paths not saved to " .. buffer_data_file() .. " (" .. tostring(detail)
        .. "); the file is as it was")
      request_redraw()
      return false, detail
    end
    -- a failed write, or an unreadable file still in place, is over
    if state.problem == "not saved" or (state.problem == "unreadable" and not state.backup) then
      state.problem = nil
      request_redraw()
    end
    state.version, state.text = nil, data_files.encode(value)
    S.buffer_autosave_blocked = false
    if detail == "written" then print("buffer paths saved to " .. buffer_data_file()) end
    return true, detail
  end

  -- The slots changed (buffer_display_changed, a bufferState report that
  -- changed something): write buffers.data if what it would hold differs
  -- from what was last written (#327), once the restore at start has run
  -- and unless an unloadable file is still in place. The restore's own
  -- loads write nothing (S.buffers_loaded is false until it ends), nor do
  -- set_start's detents (the reload they schedule does). A failed write is
  -- tried again at the next change and at exit
  remember = function()
    if not S.buffers_loaded or S.buffer_autosave_blocked then return end
    if S.lib.data_files.encode(remembered_buffers()) == S.buffer_file.text then return end
    save_buffers_to_disk()
  end

  local function preserve_unloadable_buffer_file()
    local backup = S.lib.scenes.move_aside_unloadable_file(buffer_data_file(), "buffers")
    if not backup then S.buffer_autosave_blocked = true end
    S.buffer_file.problem, S.buffer_file.backup = "unreadable", backup
  end

  -- Reload each remembered path that still exists through load_buffer. A
  -- missing or damaged file loads nothing and never stops init. A slot counts
  -- in buffers_restored once the engine reports audio in it
  -- (buffer_state_changed); a missing file's path is kept for the next save.
  local function restore_buffers_from_file()
    S.buffers_restored = 0
    S.buffer_autosave_blocked = false
    S.buffer_file.version, S.buffer_file.problem, S.buffer_file.backup = nil, nil, nil
    -- the file is parsed, never run as Lua (lib/data_files.lua, #464)
    local loaded, problem, detail = S.lib.data_files.read(buffer_data_file())
    if loaded == nil and problem == "missing" then
      print("no saved buffers file found")
      return
    end
    if type(loaded) ~= "table" then
      print("error loading buffers file: " .. tostring(detail))
      preserve_unloadable_buffer_file()
      return
    end
    -- version 1 (3.2) has no starts: every start is 0
    if (loaded.version ~= BUFFER_DATA_VERSION and loaded.version ~= 1) or type(loaded.paths) ~= "table" then
      print("error: buffers file has version " .. tostring(loaded.version) ..
        " or no path list, expected version " .. BUFFER_DATA_VERSION)
      preserve_unloadable_buffer_file()
      return
    end

    -- the first save keeps a version 1 file as buffers.data.v1 first (#467)
    if loaded.version < BUFFER_DATA_VERSION then S.buffer_file.version = loaded.version end
    local reloading = 0
    for slot = 1, NUM_BUFFERS do
      local path = loaded.paths[slot]
      local start = type(loaded.starts) == "table" and tonumber(loaded.starts[slot]) or 0
      -- the reader reads inf and nan as numbers (tab.load dropped or refused
      -- them): a start that is not finite is 0
      if not (start > -math.huge and start < math.huge) then start = 0 end
      if is_sound_file_path(path) then
        -- the file may have been deleted or be on an unmounted drive, or a
        -- take was never written
        if util.file_exists(path) then
          -- a file replaced by a shorter one since: the start stays inside it
          local _, file_seconds = file_length(path)
          if file_seconds then
            start = util.clamp(start, 0, math.max(0, file_seconds - S.performance.buffer_seconds))
          end
          load_buffer(slot, path, start)
          S.buffers[slot].restoring = true
          reloading = reloading + 1
        else
          S.buffers[slot].missing_path = path
          S.buffers[slot].start = (start and start > 0 and start < math.huge) and start or 0  -- kept with the path
          S.buffers[slot].sent_start = S.buffers[slot].start  -- what a failed load puts back
          print("buffer " .. slot .. ": " .. path .. " not found, not restored (kept for the next start)")
        end
      end
    end
    print(reloading .. " buffers reloading from " .. buffer_data_file())
  end

  -- init's restore: from here on the buffer paths are saved (whenever they
  -- change, remember, and by cleanup())
  function load_buffers_from_disk()
    restore_buffers_from_file()
    S.buffers_loaded = true
  end

  -- init's start steps: the polls (valid seconds per buffer slot, failed
  -- loads and save results, from the engine), and later, after the scenes, which may
  -- use them, the restore. A start that fails before the restore leaves
  -- S.buffers_loaded false, so cleanup() does not save (#72)
  S.register_start(S.constants.START_ORDER.buffer_polls, function()
    S.buffer_polls.state = poll.set("bufferState", buffer_state_changed)
    if S.buffer_polls.state then
      S.buffer_polls.state:start()
    else
      print("bufferState poll not found")
    end
    S.buffer_polls.load_failed = poll.set("bufferLoadFailed", buffer_load_failed)
    if S.buffer_polls.load_failed then
      S.buffer_polls.load_failed:start()
    else
      print("bufferLoadFailed poll not found")
    end
    S.buffer_polls.save_result = poll.set("bufferSaveResult", buffer_save_result)
    if S.buffer_polls.save_result then
      S.buffer_polls.save_result:start()
    else
      print("bufferSaveResult poll not found")
    end
  end)
  S.register_start(S.constants.START_ORDER.buffers_load, function()
    -- Reload the buffers remembered on exit (after the scenes, which may use them)
    load_buffers_from_disk()
    -- a file that cannot be read is named on the hint row, as the scenes'
    -- (one text for both: this flash replaces theirs)
    if S.buffer_file.problem == "unreadable" then
      S.lib.ui_flash.start("hints", S.scene_file.problem == "unreadable" and "data files unreadable (SETUP)"
        or "buffers unreadable (SETUP)", S.lib.scenes.SCENE_LOAD.start_flash_seconds)
    end
  end)

  -- cleanup()'s steps: remember each buffer's file or scratch take for the
  -- next start (unless the paths were never loaded in this session, a failed
  -- start, or the save would overwrite a buffers file that failed to load
  -- and could not be moved aside), and later stop the polls and the
  -- recording timers (the engine finishes or frees any recording itself)
  S.register_cleanup(S.constants.CLEANUP_ORDER.buffer_paths_save, function()
    if not S.buffers_loaded then
      print("buffer paths not auto-saved: they were not loaded from " .. buffer_data_file() .. " in this session")
    elseif S.buffer_autosave_blocked then
      print("buffer paths not auto-saved: " .. buffer_data_file() .. " could not be loaded")
    else
      save_buffers_to_disk()
    end
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.buffer_start_reload, function()
    -- a canceled reload's untried start goes back to what plays (after the save above)
    for slot = 1, NUM_BUFFERS do
      cancel_start_reload(slot)
      S.buffers[slot].start = S.buffers[slot].sent_start
    end
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.buffer_polls, function()
    if S.buffer_polls.state then S.buffer_polls.state:stop() end
    if S.buffer_polls.load_failed then S.buffer_polls.load_failed:stop() end
    if S.buffer_polls.save_result then S.buffer_polls.save_result:stop() end
    S.lib.record.stop_all()
  end)

  -- A slot finishes only a recording, keeps a canceled take's state only
  -- once it no longer records, checks a load only while it awaits the
  -- engine's report, never settles empty while loaded, and shows a start
  -- other than the last sent one only while a start reload is pending
  S.register_invariant("buffer slots", function()
    for slot = 1, NUM_BUFFERS do
      local buffer = S.buffers[slot]
      if buffer.finishing and not buffer.recording then
        return "slot " .. slot .. " is finishing but not recording"
      end
      if buffer.kept_state ~= nil and buffer.recording then
        return "slot " .. slot .. " records but keeps a canceled take's state"
      end
      if buffer.checking_from ~= nil and buffer.confirm_since == nil then
        return "slot " .. slot .. " is checking a load but awaits no report (confirm_since nil)"
      end
      if buffer.settled_empty and buffer.loaded then
        return "slot " .. slot .. " is loaded but settled empty (" .. tostring(buffer.settled_empty) .. ")"
      end
      -- a take is named for its own slot, on a whole-numbered scratch path (a
      -- float slot from a poll value names it "take 3.0", #300); a loaded
      -- file whose name starts with "take " is not a take
      if type(buffer.name) == "string" and buffer.name:match("^take [%d.]+$") and buffer.name ~= "take " .. slot then
        return "slot " .. slot .. " is named " .. buffer.name
      end
      if type(buffer.path) == "string" and buffer.path:sub(1, #buffer_scratch_dir) == buffer_scratch_dir
        and buffer.path:match("/buf[^/]*%.wav$") and not buffer.path:match("/buf%d+%.wav$") then
        return "slot " .. slot .. " has the scratch path " .. buffer.path
      end
      if not start_reload_clocks[slot] and buffer.start ~= buffer.sent_start then
        return "slot " .. slot .. " shows start " .. tostring(buffer.start) .. " but the load last sent was at "
          .. tostring(buffer.sent_start) .. " with no start reload pending"
      end
    end
  end)

  -- What the slot holds, derived from its fields and its take
  -- (S.lib.record.state), the first case that applies: "finishing" (whatever
  -- the take's phase: an armed replace take stopped with K3 finishes too),
  -- "armed", "loop" / "dub" / "recording" (a playable take that loops, one that does
  -- not, a replace take), "loading" (a load the engine has not confirmed,
  -- checking or not), "loaded", "unsettled" (a named load that reported no
  -- length yet; a later report adopts it), "missing" (a remembered file not
  -- found on start), "empty". nil for a slot out of range. The fill, the
  -- BUFFER page and the grid read it, through is_free
  function M.status(slot)
    if type(slot) ~= "number" or not S.buffers[slot] then return nil end
    local buffer = S.buffers[slot]
    local take = S.lib.record.state(slot)
    if buffer.finishing then return "finishing" end
    if take and take.phase == "armed" then return "armed" end
    if buffer.recording then
      if take and take.kind == "playable" then return take.loop and "loop" or "dub" end
      return "recording"
    end
    if buffer.confirm_since ~= nil then return "loading" end
    if buffer.loaded then return "loaded" end
    if buffer.settled_empty == "load" or buffer.settled_empty == "restore" then return "unsettled" end
    if buffer.missing_path then return "missing" end
    return "empty"
  end

  -- A slot nothing holds or awaits: "empty", or "missing" (its remembered
  -- file is only a path); false for a slot out of range
  function M.is_free(slot)
    local status = M.status(slot)
    return status == "empty" or status == "missing"
  end

  M.valid_buffer_slot = valid_buffer_slot
  M.buffer_state_changed = buffer_state_changed
  M.BUFFER_SETTLE = BUFFER_SETTLE
  M.display_changed = buffer_display_changed
  -- A recordBuffer was just sent for the slot (lib/record.lua's record_buffer
  -- calls it, before it sets buffer.recording, so it says the take's kind):
  -- the pending start reload is canceled either way. A replace take
  -- (`playable` false or nil) is at the server rate and has no file, so the
  -- start is 0 and the file's rate and length are forgotten; a playable
  -- recording keeps the slot's audio, so it keeps all three until it ends
  -- (lib/record.lua's "ended" report) or is canceled (it keeps them).
  function M.recording_started(slot, playable)
    if not valid_buffer_slot(slot) then return end
    cancel_start_reload(slot)
    local buffer = S.buffers[slot]
    if not playable then
      buffer.start, buffer.sent_start, buffer.sample_rate, buffer.file_seconds = 0, 0, nil, nil
    else
      buffer.start = buffer.sent_start  -- the reload that would have made a new start true is canceled
    end
  end

  -- Set the slot's file start (seconds into it), clamped to what the file
  -- leaves after a slot's length, and reload the file there once
  -- FILES.restart_seconds pass without another call (one clock per slot,
  -- canceled by the next call, a load, a clear, a recording and cleanup).
  -- Does nothing for a slot with no file length (a take, a clear, a file that
  -- did not open) and while the slot records.
  function M.set_start(slot, seconds)
    if not valid_buffer_slot(slot) or type(seconds) ~= "number" or seconds ~= seconds then return end
    local buffer = S.buffers[slot]
    if S.lib.record.state(slot) ~= nil or not buffer.file_seconds or not buffer.path then return end
    local longest = math.max(0, buffer.file_seconds - S.performance.buffer_seconds)
    if longest <= 0 then return end  -- the file fits the slot: nothing to move
    local clamped = util.clamp(seconds, 0, longest)
    if clamped == buffer.start and not start_reload_clocks[slot] then return end
    buffer.start = clamped
    cancel_start_reload(slot)
    start_reload_clocks[slot] = clock.run(function()
      clock.sleep(S.constants.FILES.restart_seconds)
      start_reload_clocks[slot] = nil  -- before load_buffer, which cancels the slot's reload
      if S.buffers[slot].path then load_buffer(slot, S.buffers[slot].path, S.buffers[slot].start) end
    end)
    request_redraw()
  end
  return M
end

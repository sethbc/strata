-- lib/buffers.lua
-- The sample buffers: what each slot holds (S.buffers), recording, loading,
-- clearing and saving them, the engine's bufferState and bufferLoadFailed
-- polls (S.buffer_polls; init starts them), and the buffer paths kept in
-- buffers.data. The functions that were global stay global;
-- valid_buffer_slot, cancel_buffer_recording_timer, buffer_state_changed
-- and buffer_data_file (a function: the path is built at call time) are
-- fields of this module's table (S.lib.buffers) for the code in strata.lua
-- that uses them. finish_buffer_take is also S.finish_buffer_take, where the
-- tests reach it.

-- At the start of a line (outside the constructor): a test finds the
-- stride by matching this line in the script's sources
local BUFFER_STATE_STRIDE = 100  -- bufferState value = slot index * 100 + valid seconds (engine bufferStateStride)

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local BUFFER_DATA_VERSION = S.constants.BUFFER_DATA_VERSION

  -- Sample buffers. The engine holds the audio; Lua tracks what each slot
  -- holds for the screen and scenes. path is the loaded file, or the scratch
  -- take the engine writes when a recording completes (or stops early).
  -- The bufferState poll settles what the slot holds: a take is loaded only
  -- once the engine reports its seconds (recording stays set, finishing
  -- marks it, until then), and a file load, shown at once, stays loaded only
  -- if the engine reports audio. confirm_since is the util.time() of the
  -- change awaiting that report (nil = settled); restoring marks a load from
  -- load_buffers_from_disk (until the engine reports its audio);
  -- settled_empty is "take" or "load" when that settled without audio (a later
  -- report of audio adopts it: a slow take or file read), else false;
  -- missing_path is a remembered file that was not found on start (kept in
  -- buffers.data). loads_sent counts the slot's loadBuffer commands (the
  -- engine counts them too and names one in its bufferLoadFailed report);
  -- pending_loads holds the newest of them, oldest first, each with the state
  -- it replaced, so a failed load can be undone (buffer_load_failed).
  S.buffers = {}
  for slot = 1, NUM_BUFFERS do
    S.buffers[slot] = {name = "empty", loaded = false, recording = false, finishing = false, restoring = false,
      settled_empty = false, seconds = 0, path = nil, confirm_since = nil, missing_path = nil,
      loads_sent = 0, pending_loads = {}}
  end
  -- per slot: clock that ends the recording state, then the finishing fallback
  S.buffer_record_clocks = {}
  -- the engine's bufferState and bufferLoadFailed polls (nil if missing)
  S.buffer_polls = {state = nil, load_failed = nil}
  -- confirm_seconds: a report of 0 s settles a take or load only this long
  -- after the change (the periodic poll can carry a value read before the
  -- engine finished: the recording timer ends just before the engine's take
  -- completes). fallback_seconds: a finishing take with no report at all
  -- (no bufferState poll) settles this long after it ended, from the slot's
  -- last known seconds. tracked_loads: a slot's newest loads a bufferLoadFailed
  -- report can still undo (a report arrives within a fade wait and a read, so
  -- more than one is only ever pending for loads sent back to back).
  local BUFFER_SETTLE = {confirm_seconds = 1, fallback_seconds = 5, tracked_loads = 4}
  S.buffers_restored = 0  -- restored slots the engine confirmed holding audio (SETUP page)
  local buffer_audio_dir = _path.audio .. "strata/"
  local buffer_scratch_dir = buffer_audio_dir .. "scratch/"  -- engine scratchDir

  local function valid_buffer_slot(slot)
    return slot >= 1 and slot <= NUM_BUFFERS
  end

  -- Buffer state is shown on the BUFFER page and the 256 grid's page 4
  local function buffer_display_changed()
    request_redraw()
    grid_redraw()
  end

  local function cancel_buffer_recording_timer(slot)
    if S.buffer_record_clocks[slot] then
      clock.cancel(S.buffer_record_clocks[slot])
      S.buffer_record_clocks[slot] = nil
    end
  end

  -- The engine writes each completed (or early-stopped) take here,
  -- overwriting the slot's previous take
  function scratch_take_path(slot)
    return buffer_scratch_dir .. "buf" .. slot .. ".wav"
  end

  -- A take or load in the slot holds audio: loaded (a take named take <n>,
  -- its path the scratch take; a load keeps its name), and a restored slot
  -- counts in buffers_restored
  function confirm_buffer_audio(slot, is_take)
    local buffer = S.buffers[slot]
    buffer.loaded = true
    buffer.settled_empty = false
    if is_take then
      buffer.name = "take " .. slot
      buffer.path = scratch_take_path(slot)
    end
    if buffer.restoring then
      buffer.restoring = false
      S.buffers_restored = S.buffers_restored + 1
    end
  end

  -- Settle a take or load awaiting the engine (confirm_since set) from the
  -- slot's seconds (confirm_buffer_audio). Without audio a take leaves the slot
  -- empty and a load is not loaded (keeping its name); settled_empty records
  -- which, so a later report of audio still adopts it. Cancels the finishing
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
      buffer.settled_empty = is_take and "take" or "load"
      if is_take then
        buffer.name = "empty"
        buffer.path = nil
      end
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
        buffer_display_changed()
      end
    end)
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
      confirm_since = nil, path = nil, missing_path = nil, file_param = _path.audio}
  end

  -- What a load replaces in the slot, for buffer_load_failed to put back: the
  -- shown state and the buf<n>_file param. A recording (or a take waiting for
  -- the engine) has nothing to put back: the engine cancels it when the load
  -- fails, so the slot becomes empty, settled_empty "take" so that a take
  -- that had already completed is still adopted from the engine's report.
  function buffer_state_before_load(slot)
    local buffer = S.buffers[slot]
    if buffer.recording or buffer.finishing then return empty_buffer_state("take") end
    return {name = buffer.name, loaded = buffer.loaded, restoring = buffer.restoring,
      settled_empty = buffer.settled_empty, confirm_since = buffer.confirm_since, path = buffer.path,
      missing_path = buffer.missing_path, file_param = params:get("buf" .. slot .. "_file")}
  end

  function load_buffer(slot, path)
    if not valid_buffer_slot(slot) or not is_sound_file_path(path) then return end
    local buffer = S.buffers[slot]
    -- remembered (with what it replaces) until a clear or recording, or
    -- tracked_loads newer loads, in case the engine reports it failed
    buffer.loads_sent = buffer.loads_sent + 1
    if #buffer.pending_loads >= BUFFER_SETTLE.tracked_loads then table.remove(buffer.pending_loads, 1) end
    table.insert(buffer.pending_loads, {number = buffer.loads_sent, path = path, previous = buffer_state_before_load(slot)})
    -- loading cancels a recording in progress in the engine
    cancel_buffer_recording_timer(slot)
    engine.loadBuffer(slot - 1, path)
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
    buffer.confirm_since = util.time()
    buffer.path = path
    buffer.missing_path = nil
    buffer_display_changed()
  end

  -- Record the live input into a slot for record_duration seconds, or, if the
  -- slot is already recording, stop early and keep what was captured. A take
  -- that has ended and waits for the engine (finishing) ignores the press.
  function record_buffer(slot)
    if not valid_buffer_slot(slot) then return end
    local buffer = S.buffers[slot]
    if buffer.finishing then return end
    cancel_buffer_recording_timer(slot)
    if buffer.recording then
      engine.stopRecord(slot - 1)
      finish_buffer_take(slot)
    else
      local duration = params:get("record_duration")
      engine.recordBuffer(slot - 1, duration, params:get("record_level"))
      set_buffer_file_param(slot, _path.audio)
      buffer.recording = true
      buffer.seconds = 0  -- the engine reports 0 s until the take completes
      buffer.pending_loads = {}  -- a failure reported for an earlier load changes nothing now
      buffer.restoring = false
      buffer.settled_empty = false
      buffer.confirm_since = nil
      buffer.missing_path = nil
      S.buffer_record_clocks[slot] = clock.run(function()
        clock.sleep(duration)
        S.buffer_record_clocks[slot] = nil
        finish_buffer_take(slot)
        buffer_display_changed()
      end)
    end
    buffer_display_changed()
  end

  function clear_buffer(slot)
    if not valid_buffer_slot(slot) then return end
    cancel_buffer_recording_timer(slot)
    engine.clearBuffer(slot - 1)
    set_buffer_file_param(slot, _path.audio)
    local buffer = S.buffers[slot]
    buffer.name = "empty"
    buffer.loaded = false
    buffer.recording = false
    buffer.finishing = false
    buffer.restoring = false
    buffer.settled_empty = false
    buffer.seconds = 0
    buffer.confirm_since = nil
    buffer.path = nil
    buffer.missing_path = nil
    buffer.pending_loads = {}  -- a failure reported for an earlier load changes nothing now
    buffer_display_changed()
  end

  -- Timestamped stereo WAV in audio/strata/, so it shows in the file browser
  function buffer_save_path(slot)
    return buffer_audio_dir .. os.date("%Y%m%d-%H%M%S") .. "-buf" .. slot .. ".wav"
  end

  function save_buffer(slot)
    if not valid_buffer_slot(slot) then return end
    -- seconds comes from the engine's poll: a load is loaded optimistically
    -- until the poll settles it, and a recording reads 0 s until it completes
    if S.buffers[slot].seconds <= 0 then
      print("buffer " .. slot .. " is empty, nothing to save")
      return
    end
    util.make_dir(buffer_audio_dir)
    local path = buffer_save_path(slot)
    engine.saveBuffer(slot - 1, path)
    print("buffer " .. slot .. " saved to " .. path)
  end

  -- bufferState poll: one slot per message, slot index * 100 + seconds. It
  -- also settles a take or load awaiting the engine (confirm_since set,
  -- settle_buffer_slot), on any report, repeated or not: audio settles it at
  -- once, 0 s only BUFFER_SETTLE.confirm_seconds after the change. A take or
  -- load that settled empty (a periodic 0 before a slow take or file read
  -- completed) is adopted when audio is reported later, as long as nothing
  -- else (load, clear, a new recording) happened in the slot since.
  local function buffer_state_changed(value)
    local slot_index = math.floor(value / BUFFER_STATE_STRIDE)
    local slot = slot_index + 1
    if not valid_buffer_slot(slot) then return end
    local seconds = value - slot_index * BUFFER_STATE_STRIDE
    local buffer = S.buffers[slot]
    local changed = buffer.seconds ~= seconds
    buffer.seconds = seconds
    local has_audio = seconds > 0
    if buffer.confirm_since ~= nil
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
    if S.grid_page == 4 then grid_redraw() end
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
    local left = emptied and empty_buffer_state(false) or failed.previous
    if found <= #pending then
      pending[found].previous = left
    else
      buffer.name = left.name
      buffer.loaded = left.loaded
      -- buffers_restored needs no undo: a restore loads into a slot that is empty at start, so no report of old audio counted it
      buffer.restoring = left.restoring
      buffer.settled_empty = left.settled_empty
      buffer.confirm_since = left.confirm_since
      buffer.path = left.path
      buffer.missing_path = left.missing_path
      set_buffer_file_param(slot, left.file_param)
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

  function save_buffers_to_disk()
    if util.file_exists(S.lib.scenes.scene_data_dir) == false then
      util.make_dir(S.lib.scenes.scene_data_dir)
    end
    -- a remembered file that was missing on start is kept (it may be on a
    -- drive that is mounted again later)
    local paths = {}
    for slot = 1, NUM_BUFFERS do
      paths[slot] = S.buffers[slot].path or S.buffers[slot].missing_path or ""
    end
    tab.save({version = BUFFER_DATA_VERSION, paths = paths}, buffer_data_file())
    print("buffer paths saved to " .. buffer_data_file())
  end

  local function preserve_unloadable_buffer_file()
    if not S.lib.scenes.move_aside_unloadable_file(buffer_data_file(), "buffers") then
      S.buffer_autosave_blocked = true
    end
  end

  -- Reload each remembered path that still exists through load_buffer. A
  -- missing or damaged file loads nothing and never stops init. A slot counts
  -- in buffers_restored once the engine reports audio in it
  -- (buffer_state_changed); a missing file's path is kept for the next save.
  function load_buffers_from_disk()
    S.buffers_restored = 0
    S.buffer_autosave_blocked = false
    if not util.file_exists(buffer_data_file()) then
      print("no saved buffers file found")
      return
    end

    -- tab.load runs the file as Lua without protection
    local ok, loaded, load_error = pcall(tab.load, buffer_data_file())
    if not ok then
      print("error: buffers file could not be read (" .. tostring(loaded) .. ")")
      preserve_unloadable_buffer_file()
      return
    end
    if type(loaded) ~= "table" then
      print("error loading buffers file: " .. tostring(load_error))
      preserve_unloadable_buffer_file()
      return
    end
    if loaded.version ~= BUFFER_DATA_VERSION or type(loaded.paths) ~= "table" then
      print("error: buffers file has version " .. tostring(loaded.version) ..
        " or no path list, expected version " .. BUFFER_DATA_VERSION)
      preserve_unloadable_buffer_file()
      return
    end

    local reloading = 0
    for slot = 1, NUM_BUFFERS do
      local path = loaded.paths[slot]
      if is_sound_file_path(path) then
        -- the file may have been deleted or be on an unmounted drive, or a
        -- take was never written
        if util.file_exists(path) then
          load_buffer(slot, path)
          S.buffers[slot].restoring = true
          reloading = reloading + 1
        else
          S.buffers[slot].missing_path = path
          print("buffer " .. slot .. ": " .. path .. " not found, not restored (kept for the next start)")
        end
      end
    end
    print(reloading .. " buffers reloading from " .. buffer_data_file())
  end

  -- The tests reach finish_buffer_take (and BUFFER_SETTLE, its upvalue) here
  S.finish_buffer_take = finish_buffer_take

  M.valid_buffer_slot = valid_buffer_slot
  M.cancel_buffer_recording_timer = cancel_buffer_recording_timer
  M.buffer_state_changed = buffer_state_changed
  M.buffer_data_file = buffer_data_file
  return M
end

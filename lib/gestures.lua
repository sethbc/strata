-- lib/gestures.lua
-- The gesture recorders (3.4, design §7), S.lib.gestures: NUM_GESTURES
-- recorders, S.gestures[k], each a norns lib/pattern_time pattern (the
-- recording, and a free loop's playback on its metro) plus Strata's state.
-- A recorder records the hand edits of control params (the param_touch
-- hook) as {id, value} events, one recorder at a time; a beat- or
-- bar-quantized loop is held in beats and played by a clock coroutine that
-- starts each loop on its beat or bar. Playback sets each param inside
-- S.lib.engine_sync.deferrable with S.gesture_playing set, so the send
-- budget holds it and no recorder records it. Params: the group
-- strata_gestures (gesture_<k>_quantize, then the hidden gesture_<k>_play,
-- discrete scene fields kept in step with the state). Storage: a PSET's
-- side file <path base>.gestures.data and the live data/strata/gestures.data,
-- through S.lib.data_files. Sources gesture1..gesture4 (the loop's phase).
-- Start step gestures_load, cleanup steps gestures_save and gestures, the
-- "gesture recorders" invariant.

return function(S)
  local M = {}
  local pattern_time = require "pattern_time"
  local NUM_GESTURES = S.constants.NUM_GESTURES

  -- The recorders' tunables: the events a recorder holds, the longest
  -- recording (from its first event), the quantize modes in option order,
  -- the beats a quantized loop's length rounds to, and the files
  local GESTURES = {
    max_events = 1024,
    max_seconds = 600,
    modes = {"free", "beat", "bar"},
    unit_beats = {beat = 1, bar = 4},
    unit_names = {beat = {"beat", "beats"}, bar = {"bar", "bars"}},
    data_version = 1,
    live_file = "gestures.data",       -- in data/strata/
    side_suffix = ".gestures.data",    -- after a PSET's path without .pset
    backup_suffix = ".bak",
  }
  M.GESTURES = GESTURES

  local function valid(k)
    return type(k) == "number" and k >= 1 and k <= NUM_GESTURES and k % 1 == 0
  end

  local function param_id(k, name) return "gesture_" .. k .. "_" .. name end

  local function mode_index(mode)
    for index, name in ipairs(GESTURES.modes) do
      if name == mode then return index end
    end
  end

  -- Per recorder: pattern (pattern_time: event, count, and a free loop's
  -- time list), state ("empty", "recording", "playing", "stopped"), quantize
  -- (a GESTURES.modes name), and for a quantized loop offsets (each
  -- event's beats from the loop's start) and length_beats, clock (its
  -- coroutine while it plays), loop_start (the beat its current loop began)
  -- and next_index (the event it plays next); length_seconds (a free
  -- loop's), loop_started_at (util.time() its current pass began),
  -- first_event_at, limit_clock (the 10-minute stop while it records) and
  -- overdubbing
  S.gestures = {}
  S.gesture_playing = false  -- set while a recorder's playback sets a param
  for k = 1, NUM_GESTURES do
    local recorder = {pattern = pattern_time.new(), state = "empty", quantize = "free", overdubbing = false}
    S.gestures[k] = recorder
  end

  -- The play param follows the state (silently)
  local function sync_play_param(k)
    local id = param_id(k, "play")
    if params.lookup[id] then
      local value = S.gestures[k].state == "playing" and 1 or 0
      if params:get(id) ~= value then params:set(id, value, true) end
    end
  end

  -- A recorder's state changed: its play param follows, the screen and
  -- grids redraw
  local function changed(k)
    sync_play_param(k)
    request_redraw()
    grid_redraw()
  end

  -- Play one event: a control param this build has is set, inside
  -- deferrable, with S.gesture_playing set; any other id is skipped (and
  -- kept in the loop)
  local function apply_event(event)
    local id = event.id
    if not params.lookup[id] or params:lookup_param(id).t ~= params.tCONTROL then return end
    local outer = S.gesture_playing
    S.gesture_playing = true
    local ran, failure = xpcall(function()
      S.lib.engine_sync.deferrable(function() params:set(id, event.value) end)
    end, with_traceback)
    S.gesture_playing = outer
    if not ran then error(failure, 0) end
  end

  for k, recorder in ipairs(S.gestures) do
    local pattern = recorder.pattern
    pattern.process = function(event)
      if pattern.step == 1 then recorder.loop_started_at = util.time() end
      apply_event(event)
    end
  end

  -- A free loop's events as beats at the current tempo: their offsets from
  -- the loop's start and its length
  local function beats_of(times, count)
    local beat_sec = clock.get_beat_sec()
    local offsets, at = {}, 0
    for index = 1, count do
      offsets[index] = at / beat_sec
      at = at + times[index]
    end
    return offsets, at / beat_sec
  end

  -- Offsets and a length in beats, the length rounded to whole units (at
  -- least one) and every offset scaled by the same factor
  local function rounded(offsets, beats, unit)
    local length = math.max(1, math.floor(beats / unit + 0.5)) * unit
    local factor = beats > 0 and length / beats or 0
    local scaled = {}
    for index, offset in ipairs(offsets) do scaled[index] = offset * factor end
    return scaled, length
  end

  local function sum(values, count)
    local total = 0
    for index = 1, count do total = total + values[index] end
    return total
  end

  -- Convert recorder k's loop to mode: beat or bar rounds its length to
  -- whole beats or bars, free goes back to seconds at the current tempo
  local function convert(recorder, mode)
    local pattern = recorder.pattern
    if mode == "free" then
      if not recorder.offsets then return end
      local beat_sec, times = clock.get_beat_sec(), {}
      for index, offset in ipairs(recorder.offsets) do
        times[index] = ((recorder.offsets[index + 1] or recorder.length_beats) - offset) * beat_sec
      end
      pattern.time = times
      recorder.offsets, recorder.length_beats = nil, nil
      recorder.length_seconds = sum(times, pattern.count)
      return
    end
    local offsets, beats = recorder.offsets, recorder.length_beats
    if not offsets then offsets, beats = beats_of(pattern.time, pattern.count) end
    recorder.offsets, recorder.length_beats = rounded(offsets, beats, GESTURES.unit_beats[mode])
    pattern.time = {}
    recorder.length_seconds = nil
  end

  -- A quantized loop's coroutine: the first loop starts on the next beat or
  -- bar, each later one length_beats after it (clock.sync, so it stays
  -- locked to Link or MIDI clock); each event plays after its offset in
  -- beats (slept at the tempo read at each event)
  local function play_quantized(recorder)
    local unit = GESTURES.unit_beats[recorder.quantize]
    local pattern = recorder.pattern
    local function on_grid(beat, step, phase) return phase + step * math.floor((beat - phase) / step + 0.5) end
    local start = on_grid(clock.sync(unit), unit, 0)
    while true do
      local length = recorder.length_beats
      recorder.loop_start, recorder.next_index = start, 1
      while recorder.next_index <= pattern.count do
        local wait = start + recorder.offsets[recorder.next_index] - clock.get_beats()
        if wait > 0 then clock.sleep(wait * clock.get_beat_sec()) end
        local index = recorder.next_index  -- an overdub meanwhile moved it past its own event
        recorder.next_index = index + 1
        apply_event(pattern.event[index])
      end
      local phase = start % length
      start = on_grid(clock.sync(length, phase - length), length, phase)
    end
  end

  -- Start recorder k's loop (a stopped one)
  local function start_playback(k)
    local recorder = S.gestures[k]
    recorder.state = "playing"
    if recorder.offsets then
      recorder.loop_start = nil
      recorder.clock = clock.run(play_quantized, recorder)
    else
      recorder.loop_started_at = util.time()
      recorder.pattern:start()
    end
  end

  -- Stop recorder k's playback (its metro or clock) and its overdub
  local function stop_playback(k)
    local recorder = S.gestures[k]
    if recorder.pattern.play == 1 then recorder.pattern:stop() end
    if recorder.clock then
      clock.cancel(recorder.clock)
      recorder.clock = nil
    end
    recorder.overdubbing, recorder.loop_start = false, nil
    recorder.pattern:set_overdub(0)
  end

  local function cancel_limit_clock(recorder)
    if recorder.limit_clock then
      clock.cancel(recorder.limit_clock)
      recorder.limit_clock = nil
    end
  end

  -- End recorder k's recording: empty with no event, else its loop (in
  -- beats when quantized), stopped, and then playing when play is true
  local function finish_recording(k, play)
    local recorder = S.gestures[k]
    local pattern = recorder.pattern
    cancel_limit_clock(recorder)
    if pattern.count == 0 then
      pattern:clear()
      recorder.state = "empty"
    else
      pattern:rec_stop()
      recorder.length_seconds = sum(pattern.time, pattern.count)
      if recorder.quantize ~= "free" then convert(recorder, recorder.quantize) end
      recorder.state = "stopped"
      if play then start_playback(k) end
    end
    changed(k)
  end

  -- One recorder takes events at a time: end every other's recording
  -- (which then plays) and overdub
  local function take_events(k)
    for other, recorder in ipairs(S.gestures) do
      if other ~= k then
        if recorder.state == "recording" then finish_recording(other, true) end
        if recorder.overdubbing then
          recorder.overdubbing = false
          recorder.pattern:set_overdub(0)
          changed(other)
        end
      end
    end
  end

  local function full(k, recorder)
    recorder.overdubbing = false
    recorder.pattern:set_overdub(0)
    header_flash("G" .. k .. " full")
  end

  -- A hand edit while recorder k records: the event, the 10-minute clock
  -- from the first, and the end at max_events
  local function record_event(k, event)
    local recorder = S.gestures[k]
    recorder.pattern:watch(event)
    if recorder.pattern.count == 1 then
      recorder.first_event_at = util.time()
      recorder.limit_clock = clock.run(function()
        clock.sleep(GESTURES.max_seconds)
        recorder.limit_clock = nil
        finish_recording(k, true)
      end)
    end
    if recorder.pattern.count >= GESTURES.max_events then
      finish_recording(k, true)
      full(k, recorder)
    end
  end

  -- A hand edit while recorder k overdubs: a free loop through
  -- pattern_time's own overdub, a quantized one inserted at its place in the
  -- beat list (kept sorted); nothing past max_events
  local function overdub_event(k, event)
    local recorder = S.gestures[k]
    local pattern = recorder.pattern
    if pattern.count >= GESTURES.max_events then
      full(k, recorder)
      changed(k)
      return
    end
    if not recorder.offsets then
      pattern:watch(event)
      return
    end
    if not recorder.loop_start then return end  -- the first loop has not started
    local position = (clock.get_beats() - recorder.loop_start) % recorder.length_beats
    local index = pattern.count + 1
    for at, offset in ipairs(recorder.offsets) do
      if offset > position then index = at; break end
    end
    table.insert(recorder.offsets, index, position)
    table.insert(pattern.event, index, event)
    pattern.count = pattern.count + 1
    if index <= recorder.next_index then recorder.next_index = recorder.next_index + 1 end
  end

  -- Hand edits of control params (encoders, arc rings, grid faders; never a
  -- recorder's playback) reach the recorder that records or overdubs
  S.register_param_touch(function(id)
    if S.gesture_playing or not params.lookup[id] or params:lookup_param(id).t ~= params.tCONTROL then return end
    for k, recorder in ipairs(S.gestures) do
      if recorder.state == "recording" then
        record_event(k, {id = id, value = params:get(id)})
      elseif recorder.overdubbing then
        overdub_event(k, {id = id, value = params:get(id)})
      end
    end
  end)

  -- The keys (design §7.2): empty -> recording (from its first event) ->
  -- playing (a free loop at once, a quantized one from its next beat or
  -- bar) -> stopped -> playing
  function M.press(k)
    if not valid(k) then return end
    local recorder = S.gestures[k]
    if recorder.state == "empty" then
      take_events(k)
      recorder.pattern:clear()
      recorder.offsets, recorder.length_beats, recorder.length_seconds = nil, nil, nil
      recorder.first_event_at = nil
      recorder.pattern:rec_start()
      recorder.state = "recording"
      changed(k)
    elseif recorder.state == "recording" then
      finish_recording(k, true)
    elseif recorder.state == "playing" then
      stop_playback(k)
      recorder.state = "stopped"
      changed(k)
    else
      start_playback(k)
      changed(k)
    end
  end

  -- Stop and empty recorder k
  function M.clear(k)
    if not valid(k) then return end
    local recorder = S.gestures[k]
    cancel_limit_clock(recorder)
    stop_playback(k)
    recorder.pattern:clear()
    recorder.offsets, recorder.length_beats, recorder.length_seconds = nil, nil, nil
    recorder.state = "empty"
    changed(k)
  end

  -- Toggle overdub on a playing recorder (it ends another's recording or
  -- overdub)
  function M.overdub(k)
    if not valid(k) then return end
    local recorder = S.gestures[k]
    if recorder.state ~= "playing" then return end
    if recorder.overdubbing then
      recorder.overdubbing = false
      recorder.pattern:set_overdub(0)
    else
      take_events(k)
      recorder.overdubbing = true
      if not recorder.offsets then recorder.pattern:set_overdub(1) end
    end
    changed(k)
  end

  function M.state(k)
    if not valid(k) then return nil end
    return S.gestures[k].state
  end

  -- "empty", "rec 3.2 s", "play 2 bars", "stop 5.0 s"
  function M.describe(k)
    if not valid(k) then return "" end
    local recorder = S.gestures[k]
    if recorder.state == "empty" then return "empty" end
    if recorder.state == "recording" then
      return string.format("rec %.1f s", recorder.first_event_at and util.time() - recorder.first_event_at or 0)
    end
    local verb = recorder.state == "playing" and "play" or "stop"
    if recorder.offsets then
      local unit = recorder.quantize
      local count = recorder.length_beats / GESTURES.unit_beats[unit]
      return string.format("%s %d %s", verb, count, GESTURES.unit_names[unit][count == 1 and 1 or 2])
    end
    return string.format("%s %.1f s", verb, recorder.length_seconds or 0)
  end

  -- The loop's phase, 0..1 (0 when it does not play): a free loop's from
  -- the time its pass began, a quantized one's from its loop's start beat
  function M.phase(k)
    if not valid(k) then return 0 end
    local recorder = S.gestures[k]
    if recorder.state ~= "playing" then return 0 end
    if recorder.offsets then
      if not recorder.loop_start then return 0 end
      return ((clock.get_beats() - recorder.loop_start) % recorder.length_beats) / recorder.length_beats
    end
    local length = recorder.length_seconds or 0
    if length <= 0 or not recorder.loop_started_at then return 0 end
    return ((util.time() - recorder.loop_started_at) % length) / length
  end

  -- A recorder's quantize param: a recorded loop converts (and keeps
  -- playing); a recording takes the mode when it stops
  local function set_quantize(k, mode)
    local recorder = S.gestures[k]
    if recorder.quantize == mode then return end
    local playing = recorder.state == "playing"
    if playing then stop_playback(k) end
    if recorder.state == "playing" or recorder.state == "stopped" then convert(recorder, mode) end
    recorder.quantize = mode
    if playing then start_playback(k) end
    changed(k)
  end

  -- A play param set (a scene recall): 1 plays a stopped recorder, 0 stops
  -- a playing one; a recorder that cannot follow (empty, recording) keeps
  -- the param in step with its state
  local function set_playing(k, value)
    local recorder = S.gestures[k]
    if value == 1 and recorder.state == "stopped" then
      start_playback(k)
    elseif value == 0 and recorder.state == "playing" then
      stop_playback(k)
      recorder.state = "stopped"
    end
    changed(k)
  end

  -- The group strata_gestures (design §7.3): the quantize options, then the
  -- hidden play params, which PSETs leave out (a PSET's recorders load
  -- stopped, from its side file)
  function M.add_params()
    params:add_group("strata_gestures", "gestures", 2 * NUM_GESTURES)
    for k = 1, NUM_GESTURES do
      params:add_option(param_id(k, "quantize"), "gesture " .. k .. " quantize", GESTURES.modes, 1)
      params:set_action(param_id(k, "quantize"), function(index) set_quantize(k, GESTURES.modes[index]) end)
    end
    for k = 1, NUM_GESTURES do
      local id = param_id(k, "play")
      params:add_binary(id, "gesture " .. k .. " play", "toggle", 0)
      params:set_action(id, function(value) set_playing(k, value) end)
      params:hide(id)
      params:set_save(id, false)
    end
  end

  -- Scenes store whether each recorder plays (a discrete field: set at a
  -- transition's end, through the param's action)
  for k = 1, NUM_GESTURES do
    S.register_scene_field({id = param_id(k, "play"), default = 0, discrete = true})
  end

  -- Storage. A recorder's record: {quantize, events = {{id, value}, ...}},
  -- with times (a free loop's pattern_time times, seconds) or beats (a
  -- quantized loop's offsets) and length_beats. A recording is saved as it
  -- would be if it stopped now
  local function stored(k)
    local recorder = S.gestures[k]
    local pattern = recorder.pattern
    local record = {quantize = recorder.quantize}
    if recorder.state == "empty" or pattern.count == 0 then return record end
    local events = {}
    for index = 1, pattern.count do
      events[index] = {id = pattern.event[index].id, value = pattern.event[index].value}
    end
    record.events = events
    local times, offsets, length = {}, recorder.offsets, recorder.length_beats
    for index = 1, pattern.count do times[index] = pattern.time[index] end
    if recorder.state == "recording" then
      times[pattern.count] = util.time() - pattern.prev_time
      if recorder.quantize ~= "free" then
        local beats
        offsets, beats = beats_of(times, pattern.count)
        offsets, length = rounded(offsets, beats, GESTURES.unit_beats[recorder.quantize])
      end
    end
    if offsets then
      local beats = {}
      for index = 1, pattern.count do beats[index] = offsets[index] end
      record.beats, record.length_beats = beats, length
    else
      record.times = times
    end
    return record
  end

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  -- nil when a stored record is well formed, else what is wrong with it
  local function record_problem(record)
    if type(record) ~= "table" or not mode_index(record.quantize) then return "a recorder has no quantize" end
    local events = record.events
    if events == nil then return nil end
    if type(events) ~= "table" or #events > GESTURES.max_events then return "a recorder's events are no list" end
    for _, event in ipairs(events) do
      if type(event) ~= "table" or type(event.id) ~= "string" or not finite(event.value) then return "a bad event" end
    end
    local free = record.quantize == "free"
    local list = free and record.times or record.beats
    if type(list) ~= "table" or #list ~= #events then return "a recorder's times do not match its events" end
    local unit = GESTURES.unit_beats[record.quantize]
    if not free and (not finite(record.length_beats) or record.length_beats < unit or record.length_beats % unit ~= 0) then
      return "a loop length that is no whole number of " .. GESTURES.unit_names[record.quantize][2]
    end
    local previous = 0
    for _, value in ipairs(list) do
      if not finite(value) or value < 0 then return "a bad event time" end
      if not free and (value < previous or value >= record.length_beats) then return "a bad event beat" end
      previous = value
    end
    return nil
  end

  -- Load a stored record into recorder k, stopped (nil: empty)
  local function load_record(k, record)
    local recorder = S.gestures[k]
    local pattern = recorder.pattern
    cancel_limit_clock(recorder)
    stop_playback(k)
    pattern:clear()
    recorder.offsets, recorder.length_beats, recorder.length_seconds = nil, nil, nil
    recorder.state = "empty"
    if record then
      recorder.quantize = record.quantize
      for index, event in ipairs(record.events or {}) do
        pattern.event[index] = {id = event.id, value = event.value}
        if record.beats then
          recorder.offsets = recorder.offsets or {}
          recorder.offsets[index] = record.beats[index]
        else
          pattern.time[index] = record.times[index]
        end
      end
      pattern.count = #pattern.event
      if pattern.count > 0 then
        recorder.state = "stopped"
        if recorder.offsets then
          recorder.length_beats = record.length_beats
        else
          recorder.length_seconds = sum(pattern.time, pattern.count)
        end
      end
      if params.lookup[param_id(k, "quantize")] then
        params:set(param_id(k, "quantize"), mode_index(record.quantize), true)
      end
    end
    sync_play_param(k)
  end

  -- Stop every recorder: playback, overdub and a recording (kept, stopped)
  local function stop_all()
    for k, recorder in ipairs(S.gestures) do
      if recorder.state == "recording" then finish_recording(k, false) end
      stop_playback(k)
      if recorder.state == "playing" then recorder.state = "stopped" end
      changed(k)
    end
  end

  -- Write every recorder to path (an empty one too, so a PSET saved over
  -- never keeps an older side file). Returns whether it was written
  local function write_file(path)
    local recorders = {}
    for k = 1, NUM_GESTURES do recorders[k] = stored(k) end
    local written, detail = S.lib.data_files.write(path, {version = GESTURES.data_version, recorders = recorders})
    if not written then print("error: gestures not saved to " .. path .. " (" .. tostring(detail) .. ")") end
    return written
  end

  -- Load every recorder from path, stopped: a missing file loads them
  -- empty; one that cannot be used is set aside (path .. ".bak", ...) with
  -- a console line, and they load empty
  local function read_file(path)
    local loaded, problem, detail = S.lib.data_files.read(path)
    local why
    if loaded == nil and problem ~= "missing" then
      why = tostring(detail)
    elseif loaded ~= nil then
      if type(loaded) ~= "table" or loaded.version ~= GESTURES.data_version or type(loaded.recorders) ~= "table" then
        why = "not a version " .. GESTURES.data_version .. " gestures file"
      else
        for k = 1, NUM_GESTURES do
          why = why or (loaded.recorders[k] ~= nil and record_problem(loaded.recorders[k])) or nil
        end
      end
    end
    if why then
      local backup, failure = S.lib.data_files.set_aside(path, GESTURES.backup_suffix)
      print("error loading gestures file " .. path .. ": " .. why .. "; "
        .. (backup and ("kept as " .. backup) or ("not moved: " .. tostring(failure))))
      loaded = nil
    end
    for k = 1, NUM_GESTURES do load_record(k, loaded and loaded.recorders[k] or nil) end
    request_redraw()
    grid_redraw()
  end

  -- The PSET's side file: written with every PSET save, read after every
  -- PSET load (every recorder stopped first), deleted with the PSET
  S.register_pset_hook({
    name = "gestures",
    write = function(path_base) write_file(path_base .. GESTURES.side_suffix) end,
    read = function(path_base)
      stop_all()
      read_file(path_base .. GESTURES.side_suffix)
    end,
    delete = function(path_base) os.remove(path_base .. GESTURES.side_suffix) end,
  })

  -- The live file: loaded at init (stopped), saved at cleanup once loaded
  local live_dir = _path.data .. "strata/"
  local live_loaded = false
  S.register_start(S.constants.START_ORDER.gestures_load, function()
    read_file(live_dir .. GESTURES.live_file)
    live_loaded = true
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.gestures_save, function()
    if not live_loaded then return end
    if util.file_exists(live_dir) == false then util.make_dir(live_dir) end
    write_file(live_dir .. GESTURES.live_file)
  end)

  -- Cleanup stops every recorder's metro and clock (and ends a recording)
  S.register_cleanup(S.constants.CLEANUP_ORDER.gestures, function()
    stop_all()
  end)

  -- The modulation sources (design §10.1): each recorder's loop phase, and
  -- MOD's row actions (E3 the quantize, K3 the press, ALT+K2 held clear,
  -- ALT+K3 overdub)
  local PRESS_HINTS = {empty = "K3:rec", recording = "K3:play", playing = "K3:stop", stopped = "K3:play"}
  for k = 1, NUM_GESTURES do
    S.register_mod_source({
      key = "gesture" .. k,
      name = "G" .. k,
      section = "gestures",
      range = {0, 1},
      value = function() return M.phase(k) end,
      describe = function() return M.describe(k) end,
      row = {
        enc = function(d) enc_param_delta(3, param_id(k, "quantize"), d) end,
        press = function() M.press(k) end,
        alt_press = function(n)
          if n == 2 then M.clear(k) elseif n == 3 then M.overdub(k) end
        end,
        hints = function(alt)
          if alt then return S.gestures[k].state == "playing" and "K3:dub" or "" end
          return PRESS_HINTS[S.gestures[k].state] .. " E3:quant"
        end,
      },
    })
  end

  -- At most one recorder records; a recorder's clock or metro runs exactly
  -- while it plays; its 10-minute clock runs exactly while it records an
  -- event or more; its play param is 1 exactly while it plays
  S.register_invariant("gesture recorders", function()
    local recording = 0
    for k, recorder in ipairs(S.gestures) do
      local pattern, playing = recorder.pattern, recorder.state == "playing"
      if recorder.state == "recording" then recording = recording + 1 end
      if (pattern.rec == 1) ~= (recorder.state == "recording") then return "G" .. k .. " records out of its state" end
      local metro_runs, clock_runs = pattern.play == 1, recorder.clock ~= nil
      if metro_runs and clock_runs then return "G" .. k .. " plays on its metro and its clock" end
      if (metro_runs or clock_runs) ~= playing then return "G" .. k .. " is " .. recorder.state .. " but its playback runs: "
        .. tostring(metro_runs or clock_runs) end
      if playing and clock_runs ~= (recorder.offsets ~= nil) then return "G" .. k .. " plays the wrong way for its loop" end
      if (recorder.limit_clock ~= nil) ~= (recorder.state == "recording" and pattern.count > 0) then
        return "G" .. k .. "'s 10-minute clock is out of step"
      end
      if recorder.overdubbing and not playing then return "G" .. k .. " overdubs but does not play" end
      if (recorder.state == "empty") ~= (pattern.count == 0 and recorder.state ~= "recording") then
        return "G" .. k .. " is " .. recorder.state .. " with " .. pattern.count .. " events"
      end
      local id = param_id(k, "play")
      if params.lookup[id] and params:get(id) ~= (playing and 1 or 0) then return id .. " is out of step" end
    end
    if recording > 1 then return recording .. " recorders record" end
  end)

  return M
end

-- lib/playheads.lua
-- Where each running buffer voice's grains start, estimated: the phase of
-- its scan is integrated from the scan the engine has (an LFO's offset,
-- tempo follow's factor, freeze, the scan hold and the scrub glide count)
-- as a speed over the span in play (the own note's region, else the
-- loop), in the voice's scan mode (wrap, bounce, one shot), in beats for a
-- voice that follows the tempo, and restarts at 0 exactly where the
-- engine's does (a grain restart, a jump, a scan mode change, a one-shot
-- voice's hit). Also the record head of a slot recording playably, and a
-- 15 Hz clock that follows all of it and redraws a grid that shows the
-- position page when its LEDs change. See docs/notes/lua/playheads.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PLAYHEADS = S.constants.PLAYHEADS
  -- the page the grids show positions on (design 3.3 section 9)
  local POSITION_PAGE = S.constants.GRID_PAGES.positions
  -- The largest buf_pos the engine's wrap takes (its lastLoopPosition,
  -- StrataLoop.sc): buf_pos 1 is the span's last start, not its first (#726)
  local LAST_POSITION = 0.999999
  -- scan_mode's option indices (lib/scan.lua)
  local MODE = {wrap = 1, bounce = 2, one_shot = 3}

  -- per voice: {phase = the scan's phase (0-1 in wrap, 0-2 in bounce,
  -- unbounded in one shot), at = the time it is true at, beat = the beat}
  local heads = {}
  local clock_id
  -- the page-5 grids' LED levels as of their last redraw (nil: none shown)
  local shown_signature
  -- per tick part (TICK_PARTS' keys): the key (`message`) of its error
  -- last printed (nil after the part ran well)
  local last_errors = {}

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx >= 1 and voice_idx <= NUM_VOICES and voice_idx % 1 == 0
  end

  local function running_buffer_voice(voice_idx)
    return valid_voice(voice_idx) and S.voices[voice_idx].active and voice_uses_buffer(voice_idx)
  end

  local function param_id(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  -- The own note's region (package 2b's S.lib.notes.own_region: a copy
  -- {start, length}, or nil) as start, length; nil for none
  local function own_region(voice_idx)
    local reader = S.lib.notes.own_region
    local region = reader and reader(voice_idx)
    if type(region) ~= "table" then return nil end
    local start, length = region[1] or region.start, region[2] or region.length
    if type(start) ~= "number" or type(length) ~= "number" or length <= 0 then return nil end
    return start, length
  end

  -- The span the voice's grains start in, as the engine has it (slotSpan,
  -- StrataLoop.sc): the own note's region, else the loop; start and length
  -- as fractions of the slot's valid region, the length cut at its end
  local function span(voice_idx)
    local start, length = own_region(voice_idx)
    if not start then
      start, length = params:get(param_id(voice_idx, "loop_start")), params:get(param_id(voice_idx, "loop_length"))
    end
    start = util.clamp(start, 0, 1)
    return start, math.min(util.clamp(length, 0, 1), 1 - start)
  end

  -- The scan's rate in spans a second, as the engine has it: the scan is
  -- a speed (1 crosses the span in its own length of audio), stopped by
  -- freeze and the hold; the glide adds its rate in spans a second
  local function scan_effective(voice_idx)
    local scan = engine_param_value(param_id(voice_idx, "buf_scan"))
    local frozen = S.lib.freeze.is_frozen(voice_idx) and 1 or 0
    local held = S.lib.positions.scan_held(voice_idx) and 1 or 0
    local slot = voice_buffer_slot(voice_idx)
    local _, length = span(voice_idx)
    local span_seconds = length * (S.buffers[slot] and S.buffers[slot].seconds or 0)
    local speed = span_seconds > 0 and 1 / span_seconds or 0
    return scan * speed * (1 - frozen) * (1 - held) + S.lib.positions.scrub_rate(voice_idx)
  end

  -- A phase kept in its mode's range: 0-1 in wrap, 0-2 in bounce (two
  -- passes), unbounded in one shot (the engine's Sweep never wraps)
  local function kept(voice_idx, phase)
    local mode = S.lib.scan.mode(voice_idx)
    if mode == MODE.bounce then return phase % 2 end
    if mode == MODE.one_shot then return phase end
    return phase % 1
  end

  -- Forget a voice's phase: its scan restarts at 0 now
  function M.reset(voice_idx)
    if not valid_voice(voice_idx) then return end
    heads[voice_idx] = {phase = 0, at = util.time(), beat = clock.get_beats()}
  end

  -- Bring a voice's phase up to now at the rate it has now: over the time
  -- since, or for a voice that follows the tempo (S.lib.scan.following)
  -- over the beats since at the beat's length now, so its estimate stays
  -- on the beat (a beat that goes back counts none). The positions module
  -- calls it before it changes the hold or the glide's rate
  function M.advance(voice_idx)
    if not valid_voice(voice_idx) then return end
    local head = heads[voice_idx]
    if not head then
      M.reset(voice_idx)
      return
    end
    local now, beat = util.time(), clock.get_beats()
    if running_buffer_voice(voice_idx) then
      local seconds
      if S.lib.scan.following(voice_idx) then
        seconds = math.max(beat - head.beat, 0) * S.lib.params_setup.beat_seconds_now()
      else
        seconds = math.max(now - head.at, 0)
      end
      if seconds > 0 then head.phase = kept(voice_idx, head.phase + scan_effective(voice_idx) * seconds) end
    end
    head.at, head.beat = math.max(now, head.at), beat
  end

  -- buf_pos, the phase up to now in its mode's range, and the mode
  local function scan_state(voice_idx)
    M.advance(voice_idx)
    local buf_pos = engine_param_value(param_id(voice_idx, "buf_pos"))
    return buf_pos, kept(voice_idx, heads[voice_idx].phase), S.lib.scan.mode(voice_idx)
  end

  -- A voice's read position (0-1 of the slot's valid region), or nil
  -- unless a buffer voice runs: the span's start + a fraction of its
  -- length, as the engine's modes give it (slotScanPosition): in wrap
  -- (buf_pos, at most its last start, + the phase) wrapped; in bounce the
  -- sum folded; in one shot held at the edges
  function M.position(voice_idx)
    if not running_buffer_voice(voice_idx) then return nil end
    local buf_pos, phase, mode = scan_state(voice_idx)
    local start, length = span(voice_idx)
    local fraction
    if mode == MODE.bounce then
      fraction = (buf_pos + phase) % 2
      if fraction > 1 then fraction = 2 - fraction end
    elseif mode == MODE.one_shot then
      fraction = util.clamp(buf_pos + phase, 0, 1)
    else
      fraction = (math.min(buf_pos, LAST_POSITION) + phase) % 1
    end
    return start + fraction * length
  end

  -- The scan's phase as engine.syncScan takes it (0-1 in wrap, 0-2 in
  -- bounce; in one shot as it runs), or nil unless a buffer voice runs
  function M.phase(voice_idx)
    if not running_buffer_voice(voice_idx) then return nil end
    local _, phase = scan_state(voice_idx)
    return phase
  end

  -- Whether a one-shot voice has played out: buf_pos + the phase strictly
  -- past 1 or below 0, where the engine's level is 0 (exactly 1 sounds)
  function M.finished(voice_idx)
    if not running_buffer_voice(voice_idx) then return false end
    local buf_pos, phase, mode = scan_state(voice_idx)
    local sum = buf_pos + phase
    return mode == MODE.one_shot and (sum > 1 or sum < 0)
  end

  -- The width grains are spread over (the position spread x the span's
  -- length), or nil unless a buffer voice runs
  function M.spread(voice_idx)
    if not running_buffer_voice(voice_idx) then return nil end
    local _, length = span(voice_idx)
    return params:get(param_id(voice_idx, "grain_spread")) * length
  end

  -- The cell (1..columns) of `columns` that a fraction is in
  function M.cell_of(fraction, columns)
    return math.min(math.max(math.floor(fraction * columns + 1e-9) + 1, 1), columns)
  end

  -- The cell (1..columns) a voice's playhead is in, or nil
  function M.column(voice_idx, columns)
    local position = M.position(voice_idx)
    if not position or type(columns) ~= "number" or columns < 1 then return nil end
    return M.cell_of(position, columns)
  end

  -- A slot's record head (0-1 of its valid region), from the "recording"
  -- report's time, the record length D and the valid length; it wraps over D
  -- in loop mode and stops at D in a one-shot. nil unless the slot records
  -- playably (a replace take plays nothing)
  function M.record_head(slot)
    if not S.lib.buffers.valid_buffer_slot(slot) then return nil end  -- the one slot check (#402)
    local state = S.lib.record.state(slot)
    if not state or state.kind ~= "playable" or state.phase ~= "recording" then return nil end
    local duration = state.seconds
    if type(duration) ~= "number" or duration <= 0 then return nil end
    local valid = math.max(S.buffers[slot].seconds or 0, duration)
    local elapsed = math.max(util.time() - state.started_at, 0)
    elapsed = state.loop and elapsed % duration or math.min(elapsed, duration)
    return elapsed / valid
  end

  -- Whether a slot reports audio (its seconds above 0): the one check of
  -- whether a voice's head means anything there, read by BUFFER's heads
  -- and ticks, moving() and the grid's position rows (#433). An empty slot
  -- and one recording a replace take report none
  function M.has_audio(slot)
    return S.lib.buffers.valid_buffer_slot(slot) and (S.buffers[slot].seconds or 0) > 0
  end

  -- Whether something drawn on a slot moves: its record head (it records
  -- playably), or a running voice's head on its audio. A replace take, and
  -- voices on a slot that holds nothing, show nothing that moves (#433)
  function M.moving(slot)
    if not S.lib.buffers.valid_buffer_slot(slot) then return false end
    if M.record_head(slot) then return true end
    if not M.has_audio(slot) then return false end
    for voice_idx = 1, NUM_VOICES do
      if running_buffer_voice(voice_idx) and voice_buffer_slot(voice_idx) == slot then return true end
    end
    return false
  end

  -- The clock's work, in three parts that each contain their own error
  -- (guarded_tick): follow the scan (an LFO moves it); end the grid holds
  -- whose grid left; and redraw the grids that show the position page when
  -- an LED they show changed (a head changing column, and also buf_pos, a
  -- loop or a bookmark changed by a param, a scene fade or an LFO). A fault
  -- that persists in one part never skips the others: a gone grid's hold is
  -- always released
  local function follow_scans()
    for voice_idx = 1, NUM_VOICES do
      if running_buffer_voice(voice_idx) then M.advance(voice_idx) end
    end
  end

  local function end_stale_holds() S.lib.positions.end_stale_holds() end

  -- Whether a connected grid shows positions now: the position page, or the
  -- page its layout record names as `strip_page` (the 128h's page 4 shows
  -- the grid voice's strip)
  local function shows_positions()
    local grid_core = S.lib.grid_core
    for port, grid_port in pairs(S.grids) do
      if grid_port.device then
        local page = grid_core.page(port)
        local layout = grid_core.layout_of(port)
        if page == POSITION_PAGE or (layout ~= nil and layout.strip_page == page) then return true end
      end
    end
    return false
  end

  local function redraw_position_grids()
    if shows_positions() then
      local signature = S.lib.positions.display_signature()
      -- the first look draws too: a change made between the grid's arrival
      -- on the page and this look (up to one tick) is in what it finds (#322)
      if signature ~= shown_signature then grid_redraw() end
      shown_signature = signature
    else
      shown_signature = nil
    end
  end

  local TICK_PARTS = {
    {key = "scan", run = follow_scans},
    {key = "holds", run = end_stale_holds},
    {key = "blink", run = function() S.lib.positions.advance_blink() end},
    {key = "redraw", run = redraw_position_grids},
  }

  -- The playhead clock's id, nil when it is not running (the cleanup test)
  function M.clock_id() return clock_id end

  local function stop_clock()
    if clock_id then
      clock.cancel(clock_id)
      clock_id = nil
    end
  end

  -- Run one tick: each part under its own xpcall (the frame's
  -- contained_call). A part's error is printed once per distinct message
  -- (that part's good run forgets it) and never ends the clock or skips
  -- another part
  local function guarded_tick()
    for _, part in ipairs(TICK_PARTS) do
      S.lib.ui_frame.contained_call(last_errors, part.key, "playhead tick", part.run)
    end
  end

  local function start_clock()
    stop_clock()
    clock_id = clock.run(function()
      while true do
        clock.sleep(1 / PLAYHEADS.update_hz)
        guarded_tick()
      end
    end)
  end

  -- Every grain restart (a voiceOn, a running voice's source switch)
  -- restarts the engine's scan at 0
  S.register_grain_restart(function(voice_idx) M.reset(voice_idx) end)
  -- A hit on a one-shot voice's own note restarts its scan (the engine's
  -- positionsHit, a retrigger's); sends nothing
  S.register_voice_hit({name = "playheads", hit = function(voice_idx, info)
    if info.slot == 1 and S.lib.scan.mode(voice_idx) == MODE.one_shot then M.reset(voice_idx) end
  end})
  S.register_start(S.constants.START_ORDER.playheads, start_clock)
  S.register_cleanup(S.constants.CLEANUP_ORDER.playheads, stop_clock)

  return M
end

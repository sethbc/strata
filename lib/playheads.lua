-- lib/playheads.lua
-- Where each running buffer voice's grains start, estimated: the phase of
-- its scan is integrated from the scan rate the engine has (an LFO's
-- offset, freeze, the scan hold and the scrub glide count), and restarts at
-- 0 exactly where the engine's does (a grain restart, a jump). Also the
-- record head of a slot recording playably, and a 15 Hz clock that follows
-- all of it and redraws a grid that shows the position page when its LEDs
-- change. See docs/notes/lua/playheads.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local PLAYHEADS = S.constants.PLAYHEADS
  -- the page the grids show positions on (design 3.3 section 9)
  local POSITION_PAGE = S.constants.GRID_PAGES.positions

  -- per voice: {phase = the scan's phase (0-1), at = the time it is true at}
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

  -- The scan's rate in loop fractions a second, as the engine has it
  local function scan_effective(voice_idx)
    local scan = engine_param_value(param_id(voice_idx, "buf_scan"))
    local frozen = S.lib.freeze.is_frozen(voice_idx) and 1 or 0
    local held = S.lib.positions.scan_held(voice_idx) and 1 or 0
    return scan * (1 - frozen) * (1 - held) + S.lib.positions.scrub_rate(voice_idx)
  end

  -- Forget a voice's phase: its scan restarts at 0 now
  function M.reset(voice_idx)
    if not valid_voice(voice_idx) then return end
    heads[voice_idx] = {phase = 0, at = util.time()}
  end

  -- Bring a voice's phase up to now at the rate it has now. The positions
  -- module calls it before it changes the hold or the glide's rate
  function M.advance(voice_idx)
    if not valid_voice(voice_idx) then return end
    local head = heads[voice_idx]
    if not head then
      M.reset(voice_idx)
      return
    end
    local now = util.time()
    if running_buffer_voice(voice_idx) and now > head.at then
      head.phase = (head.phase + scan_effective(voice_idx) * (now - head.at)) % 1
    end
    head.at = math.max(now, head.at)
  end

  -- A voice's read position (0-1 of the slot's valid region), or nil unless
  -- a buffer voice runs
  function M.position(voice_idx)
    if not running_buffer_voice(voice_idx) then return nil end
    M.advance(voice_idx)
    local start = params:get(param_id(voice_idx, "loop_start"))
    local length = params:get(param_id(voice_idx, "loop_length"))
    local buf_pos = engine_param_value(param_id(voice_idx, "buf_pos"))
    return start + ((buf_pos + heads[voice_idx].phase) % 1) * length
  end

  -- The width grains are spread over (the position spread x the loop
  -- length), or nil unless a buffer voice runs
  function M.spread(voice_idx)
    if not running_buffer_voice(voice_idx) then return nil end
    return params:get(param_id(voice_idx, "grain_spread")) * params:get(param_id(voice_idx, "loop_length"))
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

  -- Whether something on a slot moves: a running voice reads it, or it records
  function M.moving(slot)
    if not S.lib.buffers.valid_buffer_slot(slot) then return false end
    local state = S.lib.record.state(slot)
    if state and state.phase == "recording" then return true end
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
  S.register_start(S.constants.START_ORDER.playheads, start_clock)
  S.register_cleanup(S.constants.CLEANUP_ORDER.playheads, stop_clock)

  return M
end

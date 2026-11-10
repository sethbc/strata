-- lib/waveforms.lua
-- Peaks of each buffer slot's audio, for the BUFFER page's waveform and the
-- grid's page 5. The engine writes <data folder>/buf<n>.peaks (64 values, the
-- largest absolute sample per bin) before it reports a slot's length; this
-- module reads them. Never in a draw or a poll callback: a report only marks
-- the slot stale, and one clock loop reads at most one marked slot per frame
-- tick (and re-marks a slot that records playably every
-- WAVEFORMS.refresh_seconds). A file is used only if it is this slot's, in
-- version 1, holds WAVEFORM_POINTS values in 0-1 and its length (frames /
-- rate) is within LENGTH_TOLERANCE of the seconds the slot reports.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local WAVEFORM_POINTS = S.constants.WAVEFORM_POINTS
  local WAVEFORMS = S.constants.WAVEFORMS
  local UI_PAGES = S.constants.UI_PAGES
  local PEAKS_MAGIC = "strata-peaks 1"
  local LENGTH_TOLERANCE = 0.01  -- seconds: the file's length against the slot's
  local GRID_WAVEFORM_PAGE = 5   -- the grid page that draws peaks

  -- per slot: the valid points (a table of WAVEFORM_POINTS numbers), or nil
  local points = {}
  -- per slot: true while the slot awaits a read
  local marked = {}
  -- when each playable recording is next marked; the loop's clock is
  -- M.read_clock (the tests find it there)
  local playable_due = {}

  local function valid_slot(slot)
    return type(slot) == "number" and slot >= 1 and slot <= NUM_BUFFERS and slot % 1 == 0
  end

  local function peaks_path(slot)
    return S.lib.scenes.scene_data_dir .. "buf" .. slot .. ".peaks"
  end

  -- Parse a peaks file's text for slot: its points, or nil when it is not
  -- valid for the slot's reported seconds
  local function parse(slot, text)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    if lines[1] ~= PEAKS_MAGIC then return nil end
    local fields = {}
    for index = 2, #lines do
      local key, rest = lines[index]:match("^(%a+)%s*(.*)$")
      if key then fields[key] = rest end
    end
    if tonumber(fields.slot) ~= slot then return nil end
    local frames, rate = tonumber(fields.frames), tonumber(fields.rate)
    if not frames or not rate or rate <= 0 then return nil end
    if math.abs(frames / rate - S.buffers[slot].seconds) > LENGTH_TOLERANCE then return nil end
    local values = {}
    for token in (fields.peaks or ""):gmatch("%S+") do
      local value = tonumber(token)
      if not value or value ~= value or value < 0 or value > 1 then return nil end
      values[#values + 1] = value
    end
    if #values ~= WAVEFORM_POINTS then return nil end
    return values
  end

  local function same_values(first, second)
    if first == nil or second == nil then return first == second end
    for index = 1, WAVEFORM_POINTS do
      if first[index] ~= second[index] then return false end
    end
    return true
  end

  -- Read slot's peaks file now (the loop calls it; tests may too)
  local function read(slot)
    local values = nil
    if S.buffers[slot].seconds > 0 then
      local file = io.open(peaks_path(slot), "r")
      if file then
        local text = file:read("*a")
        file:close()
        values = text and parse(slot, text) or nil
      end
    end
    if same_values(points[slot], values) then return end
    points[slot] = values
    request_redraw()
    if S.lib.grid_core.any_page(GRID_WAVEFORM_PAGE) then grid_redraw() end
  end

  -- A slot's audio changed: its peaks are stale (read on a later frame tick)
  function M.stale(slot)
    if valid_slot(slot) then marked[slot] = true end
  end

  -- A slot's peaks (WAVEFORM_POINTS values, 0-1), or nil when it has none
  function M.peaks(slot)
    if not valid_slot(slot) or S.buffers[slot].seconds <= 0 then return nil end
    return points[slot]
  end

  -- A slot's peaks in n bins, each the largest of the points it covers, or nil
  function M.bins(slot, n)
    local values = M.peaks(slot)
    if not values or type(n) ~= "number" or n < 1 or n % 1 ~= 0 then return nil end
    local bins = {}
    for bin = 1, n do
      local first = math.floor((bin - 1) * WAVEFORM_POINTS / n) + 1
      local last = math.max(first, math.floor(bin * WAVEFORM_POINTS / n))
      local largest = 0
      for index = first, last do largest = math.max(largest, values[index]) end
      bins[bin] = largest
    end
    return bins
  end

  -- A slot that records playably is marked every refresh_seconds (the engine
  -- rewrites its peaks that often)
  local function mark_playable_recordings()
    local now = util.time()
    for slot = 1, NUM_BUFFERS do
      local state = S.lib.record.state(slot)
      if state and state.kind == "playable" then
        playable_due[slot] = playable_due[slot] or now + WAVEFORMS.refresh_seconds
        if now >= playable_due[slot] then
          marked[slot] = true
          playable_due[slot] = playable_due[slot] + WAVEFORMS.refresh_seconds
        end
      else
        playable_due[slot] = nil
      end
    end
  end

  -- One frame tick: re-mark playable recordings, then read one marked slot
  local function tick()
    mark_playable_recordings()
    for slot = 1, NUM_BUFFERS do
      if marked[slot] then
        marked[slot] = nil
        read(slot)
        return
      end
    end
  end

  local function stop()
    if M.read_clock then
      clock.cancel(M.read_clock)
      M.read_clock = nil
    end
  end
  M.stop = stop

  S.register_start(S.constants.START_ORDER.waveforms, function()
    stop()
    M.read_clock = clock.run(function()
      while true do
        clock.sleep(1 / UI_PAGES.FRAMES_PER_SECOND)
        tick()
      end
    end)
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.waveforms, stop)

  return M
end

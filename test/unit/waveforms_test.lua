-- test/unit/waveforms_test.lua
-- lib/waveforms.lua: reading the engine's peaks files in the frame clock's
-- loop, validating them and binning them
-- Run alone: lua test/run.lua waveforms

return function(h)
local test, assert_equal, assert_true = h.test, h.assert_equal, h.assert_true
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- Write slot's peaks file as the engine does. fields overrides the header
local function write_peaks(slot, values, fields)
  fields = fields or {}
  local folder = local_value("S").lib.scenes.scene_data_dir
  util.make_dir(folder)
  local parts = {}
  for index, value in ipairs(values) do parts[index] = string.format("%.3f", value) end
  local text = string.format("%s\nslot %d\nframes %d\nrate %d\ngeneration %d\npeaks %s\n",
    fields.magic or "strata-peaks 1", fields.slot or slot, fields.frames or 576000, fields.rate or 48000,
    fields.generation or 1, table.concat(parts, " "))
  local file = assert(io.open(folder .. "buf" .. slot .. ".peaks", "w"))
  file:write(text); file:close()
end

local function ramp(count, scale)
  local values = {}
  for index = 1, count do values[index] = (index / count) * (scale or 1) end
  return values
end

-- A bufferState report of slot's seconds
local function report(context, slot, seconds)
  context.polls.fire("bufferState", (slot - 1) * 1000 + seconds)
end

-- Run the frame clock for this many ticks
local function tick(context, ticks)
  context.clock.run_for(ticks / local_value("UI_PAGES").FRAMES_PER_SECOND + 0.001)
end

-- Count the opens of peaks files whose path matches pattern; returns the
-- counter table and a restore function
local function watch_opens(pattern)
  local counter = { count = 0, names = {} }
  local original_open = io.open
  io.open = function(path, ...)
    if tostring(path):match(pattern) then
      counter.count = counter.count + 1
      table.insert(counter.names, tostring(path):match("buf%d"))
    end
    return original_open(path, ...)
  end
  return counter, function() io.open = original_open end
end

test("a valid peaks file is read and binned", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  local values = ramp(64)
  write_peaks(1, values)       -- 576000 / 48000 = 12 s
  report(context, 1, 12)
  tick(context, 2)
  local peaks = waveforms.peaks(1)
  assert_equal(#peaks, 64)
  for index = 1, 64 do assert_true(math.abs(peaks[index] - values[index]) < 1e-3, "value " .. index) end
  local bins = waveforms.bins(1, 16)
  assert_equal(#bins, 16)
  for k = 1, 16 do assert_true(math.abs(bins[k] - values[4 * k]) < 1e-3, "bin " .. k .. " is the largest of 4 points") end
  assert_equal(#waveforms.bins(1, 8), 8)
  assert_equal(waveforms.peaks(2), nil, "a slot nothing was read for")
  assert_equal(waveforms.bins(2, 16), nil)
end)

test("bins takes the largest point it covers, wherever it is", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  local values = {}
  for index = 1, 64 do values[index] = 0.1 end
  values[2], values[7], values[63] = 0.9, 0.6, 0.8
  write_peaks(1, values); report(context, 1, 12); tick(context, 2)
  local bins = waveforms.bins(1, 16)
  assert_true(math.abs(bins[1] - 0.9) < 1e-3 and math.abs(bins[2] - 0.6) < 1e-3 and math.abs(bins[16] - 0.8) < 1e-3)
  assert_true(math.abs(bins[3] - 0.1) < 1e-3)
end)

test("a peaks file with a wrong slot, version, count, range or length is ignored", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  local cases = {
    { "slot", ramp(64), { slot = 3 } },
    { "version", ramp(64), { magic = "strata-peaks 2" } },
    { "count", ramp(63), {} },
    { "range", ramp(64, 1.2), {} },
    { "length", ramp(64), { frames = 480000 } },
  }
  report(context, 2, 12)
  for _, case in ipairs(cases) do
    write_peaks(2, case[2], case[3])
    waveforms.stale(2)
    tick(context, 3)
    assert_equal(waveforms.peaks(2), nil, case[1] .. " is ignored")
  end
  -- a missing file
  os.remove(local_value("S").lib.scenes.scene_data_dir .. "buf2.peaks")
  waveforms.stale(2); tick(context, 3)
  assert_equal(waveforms.peaks(2), nil, "a missing file")
  -- a good file after the bad ones is taken
  write_peaks(2, ramp(64)); waveforms.stale(2); tick(context, 3)
  assert_equal(#waveforms.peaks(2), 64)
  -- and a file that no longer matches the slot's seconds is not its waveform
  report(context, 2, 3)
  waveforms.stale(2); tick(context, 3)
  assert_equal(waveforms.peaks(2), nil, "the slot's length changed: the old file is not its waveform")
end)

test("a peaks file of a 44.1 kHz slot validates against its reported seconds", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  write_peaks(1, ramp(64), { frames = 441000, rate = 44100 })
  report(context, 1, 10)
  tick(context, 2)
  assert_equal(#waveforms.peaks(1), 64)
end)

test("a cleared slot has no peaks", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  write_peaks(1, ramp(64)); report(context, 1, 12); tick(context, 2)
  assert_true(waveforms.peaks(1) ~= nil)
  clear_buffer(1); report(context, 1, 0)
  assert_equal(waveforms.peaks(1), nil)
  assert_equal(waveforms.bins(1, 16), nil)
end)

test("a read that changes the values requests a redraw and redraws a page-5 grid", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local waveforms = S.lib.waveforms
  local redraws, grid_redraws = 0, 0
  local original_request, original_grid = request_redraw, grid_redraw
  request_redraw = function(...) redraws = redraws + 1; return original_request(...) end
  grid_redraw = function(...) grid_redraws = grid_redraws + 1; return original_grid(...) end
  report(context, 1, 12)
  write_peaks(1, ramp(64)); waveforms.stale(1)
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 1)
  redraws, grid_redraws = 0, 0
  tick(context, 2)
  assert_equal(redraws, 1, "one redraw request for the changed values")
  assert_equal(grid_redraws, 0, "a grid on page 1 is left alone")
  waveforms.stale(1); redraws, grid_redraws = 0, 0
  tick(context, 2)
  assert_equal(redraws + grid_redraws, 0, "the same values again: neither")
  write_peaks(1, ramp(64, 0.5), { generation = 2 }); waveforms.stale(1)
  S.lib.grid_core.set_page(1, 5)
  redraws, grid_redraws = 0, 0
  tick(context, 2)
  assert_equal(redraws, 1); assert_true(grid_redraws >= 1, "a grid on page 5 is redrawn (the playhead clock's first look draws too, #322)")
  request_redraw, grid_redraw = original_request, original_grid
end)

test("peaks are read in the frame clock's loop, never in a draw or a poll callback", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  write_peaks(2, ramp(64)); write_peaks(3, ramp(64))
  local opened, restore = watch_opens("%.peaks$")
  report(context, 2, 12)
  assert_equal(opened.count, 0, "the poll callback reads nothing")
  report(context, 3, 12)
  redraw()
  assert_equal(opened.count, 0, "nor does a draw")
  tick(context, 1)
  assert_equal(opened.count, 1, "one slot per tick")
  assert_equal(opened.names[1], "buf2")
  tick(context, 1)
  assert_equal(opened.count, 2); assert_equal(opened.names[2], "buf3")
  tick(context, 5)
  assert_equal(opened.count, 2, "nothing marked, nothing read")
  restore()
  assert_true(S.lib.waveforms.peaks(2) ~= nil and S.lib.waveforms.peaks(3) ~= nil)
end)

test("a repeated report of the same seconds does not mark the slot again", function()
  local context = load_strata(); finish_startup(context)
  write_peaks(1, ramp(64))
  local opened, restore = watch_opens("%.peaks$")
  report(context, 1, 12); tick(context, 2)
  report(context, 1, 12); report(context, 1, 12); tick(context, 4)
  restore()
  assert_equal(opened.count, 1, "the periodic poll repeats unchanged values")
end)

test("a playable recording's peaks are reread every 0.5 s", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  write_peaks(3, ramp(64))
  report(context, 3, 12)
  tick(context, 2)
  -- the slot records playably (lib/record.lua's state says so)
  local playable = true
  local original_state = S.lib.record.state
  S.lib.record.state = function(slot)
    if slot == 3 and playable then return { kind = "playable", phase = "recording" } end
    return original_state(slot)
  end
  local opened, restore = watch_opens("buf3%.peaks$")
  context.clock.run_for(1.6)
  assert_equal(opened.count, 3, "three reads in 1.6 s")
  playable = false
  context.clock.run_for(2)
  assert_equal(opened.count, 3, "none once it ends")
  restore()
  S.lib.record.state = original_state
end)

test("cleanup stops the read loop", function()
  local context = load_strata(); finish_startup(context)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "no clock left")
end)

end

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

-- #404 (1): the length tolerance is 0.01 s: a file 0.05 s off the slot's
-- reported seconds is another take's, one 0.005 s off is this one's
test("a peaks file 0.05 s off the slot's length is refused, 0.005 s off is taken", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  report(context, 1, 12)
  write_peaks(1, ramp(64), { frames = 576000 + 2400 })   -- 12.05 s
  waveforms.stale(1); tick(context, 3)
  assert_equal(waveforms.peaks(1), nil, "0.05 s off")
  write_peaks(1, ramp(64), { frames = 576000 - 2400 })   -- 11.95 s
  waveforms.stale(1); tick(context, 3)
  assert_equal(waveforms.peaks(1), nil, "0.05 s short")
  write_peaks(1, ramp(64), { frames = 576000 + 240 })    -- 12.005 s
  waveforms.stale(1); tick(context, 3)
  assert_equal(#waveforms.peaks(1), 64, "within 0.01 s")
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

-- the engine writes a changing loop's file at most every 2 s (#523), and
-- the loop rereads it as often
test("a playable recording's peaks are reread every 2 s", function()
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
  context.clock.run_for(6.4)
  assert_equal(opened.count, 3, "three reads in 6.4 s")
  playable = false
  context.clock.run_for(4)
  assert_equal(opened.count, 3, "none once it ends")
  restore()
  S.lib.record.state = original_state
end)

-- #401: a new length means new audio, so the old overview goes at once,
-- not when the loop reaches the slot's new file
test("a slot whose length changes forgets its old peaks at once (#401)", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  write_peaks(1, ramp(64, 0.9)); report(context, 1, 12); tick(context, 2)
  assert_true(math.abs(waveforms.peaks(1)[64] - 0.9) < 1e-3, "a.wav's overview")
  -- b.wav loads over it: the engine reports 0 s, then b's length once b's file is in place
  report(context, 1, 0)
  write_peaks(1, ramp(64, 0.2), { frames = 240000, generation = 2 })
  report(context, 1, 5)
  assert_equal(waveforms.peaks(1), nil, "no overview before the new file is read")
  tick(context, 1)
  assert_true(math.abs(waveforms.peaks(1)[64] - 0.2) < 1e-3, "then b.wav's")
  -- a length that changes with no 0 s between (a dub arming over shorter audio)
  write_peaks(1, ramp(64, 0.4), { frames = 480000, generation = 3 })
  report(context, 1, 10)
  assert_equal(waveforms.peaks(1), nil, "the old length's overview goes too")
  tick(context, 1)
  assert_true(math.abs(waveforms.peaks(1)[64] - 0.4) < 1e-3)
end)

-- ... and a load of a file as long as the one it replaces, whose length
-- report changes nothing: the load itself forgets the overview; a load
-- that fails gives the old one back
test("a load over audio of the same length forgets the old overview until its own is read (#401)", function()
  local context = load_strata(); finish_startup(context)
  local waveforms = local_value("S").lib.waveforms
  load_buffer(1, "/tmp/a.wav")
  write_peaks(1, ramp(64, 0.9), { frames = 480000 })   -- 10 s
  report(context, 1, 10); tick(context, 2)
  assert_true(math.abs(waveforms.peaks(1)[64] - 0.9) < 1e-3, "a.wav's overview")
  load_buffer(1, "/tmp/b.wav")
  assert_equal(waveforms.peaks(1), nil, "nothing of a.wav once b.wav is sent")
  tick(context, 3)
  assert_equal(waveforms.peaks(1), nil, "a.wav's file is not read back while b.wav loads")
  write_peaks(1, ramp(64, 0.2), { frames = 480000, generation = 2 })
  report(context, 1, 10); tick(context, 2)
  assert_true(waveforms.peaks(1) ~= nil and math.abs(waveforms.peaks(1)[64] - 0.2) < 1e-3, "then b.wav's")
  -- a load that fails puts b.wav back, and its overview with it
  load_buffer(1, "/tmp/missing.wav")
  assert_equal(waveforms.peaks(1), nil)
  context.polls.fire("bufferLoadFailed", (3 * 2) * 8.0 + 0)
  tick(context, 2)
  assert_equal(local_value("buffers")[1].name, "b.wav", "the failed load is undone")
  assert_true(waveforms.peaks(1) ~= nil and math.abs(waveforms.peaks(1)[64] - 0.2) < 1e-3, "and b.wav's overview is back")
end)

test("a playable recording's rereads keep its overview between reads (#401)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  write_peaks(3, ramp(64)); report(context, 3, 12); tick(context, 2)
  local original_state = S.lib.record.state
  S.lib.record.state = function(slot)
    if slot == 3 then return { kind = "playable", phase = "recording" } end
    return original_state(slot)
  end
  local gaps = 0
  for _ = 1, 30 do
    tick(context, 1)
    if S.lib.waveforms.peaks(3) == nil then gaps = gaps + 1 end
  end
  S.lib.record.state = original_state
  assert_equal(gaps, 0, "a dub's waveform never blinks")
end)

-- #330: one error in a tick (a read, or the grid redraw it calls) never ends
-- the loop for the rest of the session
test("a tick that raises is reported once and the loop goes on reading (#330)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local waveforms = S.lib.waveforms
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  local real_grid_redraw, real_print = grid_redraw, print
  local raised, lines = 0, {}
  grid_redraw = function(...)
    if raised < 2 then raised = raised + 1; error("grid boom") end
    return real_grid_redraw(...)
  end
  print = function(text) lines[#lines + 1] = tostring(text) end
  local ok, problem = pcall(function()
    write_peaks(1, ramp(64)); report(context, 1, 12); tick(context, 2)
    write_peaks(2, ramp(64)); report(context, 2, 12); tick(context, 2)
  end)
  grid_redraw, print = real_grid_redraw, real_print
  assert_true(ok, tostring(problem))
  assert_equal(raised, 2, "both reads redrew the page-5 grid, and it raised")
  assert_equal(#context.clock.take_errors(), 0, "the scheduler saw no clock error")
  assert_true(waveforms.read_clock ~= nil, "the loop's clock is still there")
  local failed = 0
  for _, line in ipairs(lines) do
    if line:find("strata: peaks read failed: ", 1, true) == 1 then failed = failed + 1 end
  end
  assert_equal(failed, 1, "the same error twice prints once")
  write_peaks(3, ramp(64, 0.5)); report(context, 3, 12); tick(context, 2)
  assert_true(waveforms.peaks(3) ~= nil and math.abs(waveforms.peaks(3)[64] - 0.5) < 1e-3, "a slot marked later is still read")
end)

-- #381: the mover's poll steps are named once, beside peaksMoverTimeout,
-- and used by name in both files (StrataWaveform.sc and StrataFiles.sc)
test("the peaks mover's poll steps are named, never written as numbers (#381)", function()
  local stubs = h.stubs
  local function source(name)
    local file = assert(io.open(h.repo_root .. "/lib/engine/" .. name, "r"))
    local text = file:read("*a"); file:close()
    return stubs.strip_sc_comments(text)
  end
  local waveform, files = source("StrataWaveform.sc"), source("StrataFiles.sc")
  assert_equal(waveform:match("peaksMoverPollStep%s*{%s*%^%s*([%d.]+)%s*}"), "0.002", "the 2 ms step")
  assert_equal(waveform:match("peaksMoverSlowPollStep%s*{%s*%^%s*([%d.]+)%s*}"), "0.05", "the 50 ms step")
  for name, text in pairs({ ["StrataWaveform.sc"] = waveform, ["StrataFiles.sc"] = files }) do
    local bare = text:gsub("peaksMover%a*PollStep%s*{%s*%^%s*[%d.]+%s*}", "")
    for literal in bare:gmatch("%f[%w.]0%.0%d*%f[^%w.]") do
      assert_true(literal ~= "0.002" and literal ~= "0.05", name .. " writes the step " .. literal .. " as a number")
    end
  end
end)

-- #523: Lua rereads a recording slot's peaks file as often as the engine
-- may write it (WAVEFORMS.refresh_seconds, lib/constants.lua, against the
-- engine's peakWriteSeconds in StrataRecord.sc)
local function engine_write_seconds(source)
  return tonumber(h.stubs.strip_sc_comments(source):match("peakWriteSeconds%s*{%s*%^%s*([%d.]+)%s*}"))
end
local function interval_problem(source, refresh_seconds)
  local engine_seconds = engine_write_seconds(source)
  if engine_seconds == nil then return "the engine has no peakWriteSeconds" end
  if engine_seconds ~= refresh_seconds then
    return "the engine writes every " .. engine_seconds .. " s, Lua rereads every " .. tostring(refresh_seconds) .. " s"
  end
  return nil
end

test("the waveform reread interval equals the engine's peaks write interval (#523)", function()
  load_strata()
  local refresh_seconds = local_value("WAVEFORMS").refresh_seconds
  local source = h.engine_sources()
  assert_equal(interval_problem(source, refresh_seconds), nil, "WAVEFORMS.refresh_seconds = peakWriteSeconds")
  assert_equal(engine_write_seconds(source), 2, "the engine's peakWriteSeconds")
  -- either side changed alone is caught; a commented-out value is not read
  assert_true(interval_problem(source, refresh_seconds / 4) ~= nil, "caught: Lua's interval changed")
  assert_true(interval_problem("    peakWriteSeconds { ^3 }\n", refresh_seconds) ~= nil, "caught: the engine's changed")
  assert_true(interval_problem("    // peakWriteSeconds { ^2 }\n", refresh_seconds) ~= nil, "caught: only a comment holds it")
end)

test("cleanup stops the read loop", function()
  local context = load_strata(); finish_startup(context)
  cleanup()
  assert_equal(context.clock.pending_count(), 0, "no clock left")
end)

end

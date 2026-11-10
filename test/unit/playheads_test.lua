-- test/unit/playheads_test.lua
-- lib/playheads.lua: the playhead estimate of each running buffer voice
-- (position, spread, column), the record head, `moving`, and the 15 Hz
-- clock that integrates the scan and redraws a page-5 grid when its LEDs
-- change
-- Run alone: lua test/run.lua playheads

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- Voice 1 (running) on slot 1, holding 16 s
local function buffer_voice()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  return context, S
end

test("a scanning buffer voice's playhead integrates its scan", function()
  local context, S = buffer_voice()
  params:set("v1_buf_pos", 0.25)
  params:set("v1_buf_scan", 0.1)
  context.clock.run_for(2)
  assert_near(S.lib.playheads.position(1), 0.45, 1e-6, "0.25 + 2 s of 0.1 a second")
  context.clock.run_for(8)
  assert_near(S.lib.playheads.position(1), 0.25 + 0.1 * 10 - 1, 1e-6, "wrapped at 1 (here 0.25)")
  -- inside a loop it stays inside it
  params:set("v1_loop_length", 0.5)
  params:set("v1_loop_start", 0.25)
  S.lib.playheads.reset(1)
  params:set("v1_buf_pos", 0)
  context.clock.run_for(5)
  local position = S.lib.playheads.position(1)
  assert_true(position >= 0.25 and position < 0.75, "inside the loop, got " .. position)
  assert_near(position, 0.25 + 0.5 * ((0.1 * 5) % 1), 1e-6, "loop_start + phase x loop_length")
end)

test("the playhead follows an LFO-moved scan, freeze, the scan hold and the glide", function()
  local context, S = buffer_voice()
  params:set("v1_buf_pos", 0)
  params:set("v1_buf_scan", 0.1)
  S.lib.playheads.reset(1)
  S.engine_param_values.v1_buf_scan = 0.2  -- an LFO raised the scan the engine has
  context.clock.run_for(2)
  assert_near(S.lib.playheads.position(1), 0.4, 1e-6, "the sent scan counts")
  S.engine_param_values.v1_buf_scan = nil

  S.lib.playheads.reset(1)
  local real_is_frozen = S.lib.freeze.is_frozen
  S.lib.freeze.is_frozen = function() return true end
  context.clock.run_for(2)
  assert_near(S.lib.playheads.position(1), 0, 1e-6, "frozen: no scan")
  S.lib.freeze.is_frozen = real_is_frozen

  S.lib.playheads.reset(1)
  S.lib.positions.hold_scan(1, true)
  context.clock.run_for(2)
  assert_near(S.lib.playheads.position(1), 0, 1e-6, "scan held: no scan")
  S.lib.positions.hold_scan(1, false)

  params:set("v1_buf_scan", 0)
  S.lib.playheads.reset(1)
  local real_rate = S.lib.positions.scrub_rate
  S.lib.positions.scrub_rate = function() return 0.1 end  -- the glide's sent rate, its decay stubbed out
  context.clock.run_for(1)
  assert_near(S.lib.playheads.position(1), 0.1, 1e-6, "the glide adds its rate to the scan")
  S.lib.positions.scrub_rate = real_rate
end)

test("the playhead resets on voiceOn, a source switch and a jump", function()
  local context, S = buffer_voice()
  params:set("v1_buf_pos", 0.25)
  params:set("v1_buf_scan", 0.1)
  context.clock.run_for(2)
  assert_near(S.lib.playheads.position(1), 0.45, 1e-6)
  toggle_voice(1); toggle_voice(1)
  assert_near(S.lib.playheads.position(1), 0.25, 1e-6, "voiceOn restarts the scan")
  context.clock.run_for(2)
  assert_near(S.lib.playheads.position(1), 0.45, 1e-6)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 2)
  assert_near(S.lib.playheads.position(1), 0.25, 1e-6, "a source switch restarts it")
  context.clock.run_for(2)
  S.lib.positions.jump(1, 0.5)
  assert_near(S.lib.playheads.position(1), 0.5, 1e-6, "a jump restarts it at the target")
end)

test("position is nil for a synth, input or stopped voice", function()
  local context, S = buffer_voice()
  params:set("v1_source", 1)
  params:set("v2_source", S.constants.SOURCE_INPUT)
  assert_true(S.voices[1].active and S.voices[2].active, "voices 1 and 2 run")
  params:set("v3_source", S.constants.SOURCE_SYNTH + 1)
  assert_true(not S.voices[3].active, "voice 3 is stopped")
  assert_equal(S.lib.playheads.position(1), nil, "synth")
  assert_equal(S.lib.playheads.position(2), nil, "input")
  assert_equal(S.lib.playheads.position(3), nil, "stopped")
  assert_equal(S.lib.playheads.position(8), nil, "no such voice")
  assert_equal(S.lib.playheads.column(1, 16), nil, "no column either")
end)

test("spread is the position spread times the loop length", function()
  local _, S = buffer_voice()
  params:set("v1_grain_spread", 0.25)
  params:set("v1_loop_length", 0.5)
  assert_near(S.lib.playheads.spread(1), 0.125, 1e-6)
  params:set("v1_source", 1)
  assert_equal(S.lib.playheads.spread(1), nil, "a synth voice has none")
end)

test("column is the playhead's cell among n", function()
  local _, S = buffer_voice()
  params:set("v1_buf_pos", 0.5)
  S.lib.playheads.reset(1)
  assert_equal(S.lib.playheads.column(1, 16), 9)
  assert_equal(S.lib.playheads.column(1, 8), 5)
  params:set("v1_buf_pos", 0.99)
  assert_equal(S.lib.playheads.column(1, 16), 16, "the last cell")
end)

-- The "recording" report's state as lib/record.lua gives it
local function stub_recording(S, slot, seconds, loop, offset)
  S.lib.record.state = function(asked)
    if asked ~= slot then return nil end
    return {number = 1, kind = "playable", phase = "recording", started_at = util.time() - offset, seconds = seconds,
      loop = loop}
  end
end

test("the record head wraps over D in loop mode", function()
  local _, S = buffer_voice()
  assert_equal(S.lib.playheads.record_head(1), nil, "none while idle")
  stub_recording(S, 1, 4, true, 5)
  assert_near(S.lib.playheads.record_head(1), 0.0625, 1e-6, "5 s into a loop of 4 s: 1 s of 16")
  stub_recording(S, 1, 4, true, 2)
  assert_near(S.lib.playheads.record_head(1), 0.125, 1e-6, "2 s in: 2 s of 16")
  stub_recording(S, 1, 4, false, 6)
  assert_near(S.lib.playheads.record_head(1), 0.25, 1e-6, "a one-shot stops at D")
  assert_equal(S.lib.playheads.record_head(2), nil, "another slot has none")
  S.lib.record.state = function() return {number = 1, kind = "take", phase = "recording", started_at = util.time(),
    seconds = 4, loop = false} end
  assert_equal(S.lib.playheads.record_head(1), nil, "a replace take plays nothing: no head")
  S.lib.record.state = function() return {number = 1, kind = "playable", phase = "armed", started_at = util.time(),
    seconds = 4, loop = true} end
  assert_equal(S.lib.playheads.record_head(1), nil, "armed: not recording yet")
end)

test("moving: a slot a running voice reads, or that records", function()
  local _, S = buffer_voice()
  assert_true(S.lib.playheads.moving(1), "voice 1 runs on slot 1")
  assert_true(not S.lib.playheads.moving(2), "nothing reads slot 2")
  toggle_voice(1)
  assert_true(not S.lib.playheads.moving(1), "voice 1 stopped")
  stub_recording(S, 2, 4, true, 0)
  assert_true(S.lib.playheads.moving(2), "a recording slot moves")
  S.lib.record.state = function() return {number = 1, kind = "playable", phase = "armed", started_at = util.time(),
    seconds = 4, loop = true} end
  assert_true(not S.lib.playheads.moving(2), "an armed slot waits: BUFFER does not animate")
end)

-- The refresh count of a grid on port 1 showing page 5
local function page_five_grid(context, cols, rows)
  local device = context.grid.plug(1, cols or 16, rows or 16)
  local S = local_value("S")
  S.lib.grid_core.set_page(1, 5)
  context.clock.run_for(0.5)
  return device
end

test("the clock redraws the grid when a page-5 grid's LED levels change", function()
  local context, S = buffer_voice()
  toggle_voice(1)  -- stopped: no head moves
  local device = page_five_grid(context)
  local before = device.refresh_count
  context.clock.run_for(1)
  assert_equal(device.refresh_count, before, "nothing changed: no redraw in 1 s")

  params:set("v1_buf_pos", 0.5)
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device.refresh_count, before + 1, "buf_pos moved the stopped voice's head: one redraw")
  context.clock.run_for(1)
  assert_equal(device.refresh_count, before + 1, "and no more")

  params:set("v1_loop_start", 0.25)
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device.refresh_count, before + 2, "a loop start change: one redraw")
  params:set("v1_loop_length", 0.5)
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device.refresh_count, before + 3, "a loop length change: one redraw")

  params:set("v1_bookmark_2", 0.9)
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device.refresh_count, before + 4, "a bookmark change: one redraw")

  S.lib.grid_core.set_page(1, 1)
  context.clock.run_for(0.2)
  local on_page_one = device.refresh_count
  params:set("v1_buf_pos", 0.1)
  context.clock.run_for(1)
  assert_equal(device.refresh_count, on_page_one, "a grid on page 1: the clock redraws nothing")
end)

test("a running playhead changing column redraws a page-5 grid once per column", function()
  local context, S = buffer_voice()
  params:set("v1_buf_pos", 0)
  params:set("v1_buf_scan", 0.0625)  -- one cell of 16 a second
  S.lib.playheads.reset(1)
  local device = page_five_grid(context)
  local before = device.refresh_count
  context.clock.run_for(4)
  local redraws = device.refresh_count - before
  assert_true(redraws >= 3 and redraws <= 5, "about one redraw a column, got " .. redraws)
end)

test("a failing tick is reported and the clock keeps ticking", function()
  local context, S = buffer_voice()
  local calls = 0
  S.lib.positions.end_stale_holds = function()
    calls = calls + 1
    if calls == 1 then error("tick boom") end
  end
  context.clock.run_for(0.3)
  assert_true(calls >= 3, "the first call raised and later ones came, got " .. calls)
  assert_true(S.lib.playheads.clock_id() ~= nil, "the clock is still running")
  assert_equal(#context.clock.take_errors(), 0, "the scheduler reported no clock error")
end)

test("a tick that keeps failing prints its error once, and again after a good tick", function()
  local context, S = buffer_voice()
  local lines = {}
  local real_print = print
  print = function(text) lines[#lines + 1] = tostring(text) end
  local ok, err = pcall(function()
    local failure = "tick boom"
    S.lib.positions.end_stale_holds = function() if failure then error(failure) end end
    local function failed_lines()
      local count = 0
      for _, line in ipairs(lines) do
        if line:find("strata: playhead tick failed: ", 1, true) == 1 then count = count + 1 end
      end
      return count
    end
    context.clock.run_for(0.5)
    assert_equal(failed_lines(), 1, "the same error on every tick prints once")
    failure = nil
    context.clock.run_for(0.2)
    failure = "tick boom"
    context.clock.run_for(0.2)
    assert_equal(failed_lines(), 2, "printed again after a good tick")
    failure = "another boom"
    context.clock.run_for(0.2)
    assert_equal(failed_lines(), 3, "a different message prints at once")
  end)
  print = real_print
  if not ok then error(err, 0) end
end)

test("the clock ends with cleanup", function()
  local context = buffer_voice()
  local device = page_five_grid(context)
  cleanup()
  local before = device.refresh_count
  params:set("v1_buf_pos", 0.9)
  context.clock.run_for(1)
  assert_equal(device.refresh_count, before, "no redraw after cleanup")
end)

end

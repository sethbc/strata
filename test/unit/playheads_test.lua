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

test("a change within the first tick after a grid reaches page 5 is drawn (#322)", function()
  local context, S = buffer_voice()
  toggle_voice(1)
  local device = context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  params:set("v1_buf_pos", 0.5)  -- before the clock's first look at the page
  local before = device.refresh_count
  context.clock.run_for(1 / 15 + 0.01)
  assert_true(device.refresh_count > before, "the first look draws what it finds")
  local after = device.refresh_count
  context.clock.run_for(1)
  assert_equal(device.refresh_count, after, "and then only a change redraws")
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
  assert_equal(#context.take_script_errors(), 1, "the tick printed its error once (#473)")
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

-- The final review's item 7: each part of the tick contains its own error
test("a tick whose estimate fails every time still releases a gone grid's hold", function()
  local context, S = buffer_voice()
  params:set("v2_source", S.constants.SOURCE_SYNTH + 1)
  assert_true(S.voices[2].active, "voice 2 runs on slot 1 too")
  local positions = S.lib.positions
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  positions.strip_key(1, 1, "hold", 1)
  assert_equal(positions.scan_held(1), true, "the grid holds voice 1")
  -- the estimate fails on every tick, at voice 2 (voice 1's own advance,
  -- which the release runs, still works)
  local real_advance, failures = S.lib.playheads.advance, 0
  S.lib.playheads.advance = function(voice_idx)
    if voice_idx == 2 then failures = failures + 1; error("estimate boom") end
    return real_advance(voice_idx)
  end
  local real_print = print
  print = function() end
  local ok, err = pcall(function()
    context.grid.unplug(1)
    context.clock.run_for(0.3)
  end)
  print = real_print
  S.lib.playheads.advance = real_advance
  if not ok then error(err, 0) end
  assert_true(failures >= 2, "the estimate failed on every tick, " .. failures .. " times")
  assert_equal(positions.scan_held(1), false, "the gone grid's hold is released all the same")
  assert_true(S.lib.playheads.clock_id() ~= nil, "the clock is still running")
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

-- #593: a bookmark that waits for its beat or bar blinks on the position page
local function bar_wait_grid(cols, rows)
  local context, S = buffer_voice()
  toggle_voice(1)
  local device = page_five_grid(context, cols, rows)
  params:set("quantize_actions", 3)  -- bar
  context.clock.run_for((1.5 - clock.get_beats()) * clock.get_beat_sec())
  return context, S, device
end

-- The 256's LED of voice v's bookmark key n (its strip is on row 8 + v)
local function key_led(device, voice_idx, n) return device:get_led(n, 8 + voice_idx) end

local function snapshot(device)
  local cells = {}
  for x = 1, device.cols do
    for y = 1, device.rows do cells[#cells + 1] = device:get_led(x, y) end
  end
  return table.concat(cells, ",")
end

-- Tick by tick until the key's LED leaves the waiting levels: the landing's
-- repaint, in whichever call delivers it (the playheads clock can share the
-- bar's tick, #588). After each tick: the key's LED, the repaints that tick
-- made and whether the bookmark still waits (each tick is one clock step of
-- 1 / 15 s)
local function trace(context, S, device, voice_idx, n)
  local LEVELS = S.lib.positions.LEVELS
  local steps = {}
  local last, count = key_led(device, voice_idx, n), device.refresh_count
  for _ = 1, 60 do
    context.clock.run_for(1 / 15)
    local led = key_led(device, voice_idx, n)
    -- a step that ends before the clock's next tick has seen nothing yet
    if #steps > 0 or led ~= last or device.refresh_count ~= count then
      steps[#steps + 1] = {led = led, changed = led ~= last, repaints = device.refresh_count - count,
        waiting = S.lib.positions.waiting_bookmark(voice_idx) ~= nil}
    end
    last, count = led, device.refresh_count
    if #steps > 0 and led ~= LEVELS.waiting_high and led ~= LEVELS.waiting_low then break end
  end
  return steps
end

test("a waiting bookmark's key blinks on the grid's LED and repaints once per phase (#593)", function()
  local context, S, device = bar_wait_grid()
  local LEVELS = S.lib.positions.LEVELS
  local steady = key_led(device, 1, 2)
  assert_equal(steady, LEVELS.bookmark, "set, not waiting: the bookmark level")
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  local steps = trace(context, S, device, 1, 2)
  local highs, lows, changes = 0, 0, 0
  for index, step in ipairs(steps) do
    local landed = index == #steps
    assert_equal(step.repaints, step.changed and 1 or 0, "tick " .. index .. ": one repaint exactly when the LED changed")
    if landed then
      assert_equal(step.led, LEVELS.recalled, "the recall landed: the recalled level")
      assert_true(step.changed, "and the landing repainted")
      assert_true(not step.waiting, "the bookmark no longer waits")
    else
      assert_true(step.led == LEVELS.waiting_high or step.led == LEVELS.waiting_low, "waiting: a waiting level, got " .. step.led)
      -- the landing repaints in the tick that delivers it or in the next
      assert_true(step.waiting or index == #steps - 1, "tick " .. index .. ": waiting until the tick before the repaint at the latest")
      if step.led == LEVELS.waiting_high then highs = highs + 1 else lows = lows + 1 end
      if step.changed then changes = changes + 1 end
    end
  end
  assert_true(highs >= LEVELS.waiting_ticks - 1 and lows >= LEVELS.waiting_ticks - 1, "both levels held for a phase")
  assert_true(changes >= 3, "the wait's start and at least two phase changes repainted, got " .. changes)
  context.clock.run_for(1)
  assert_equal(key_led(device, 1, 2), LEVELS.recalled, "and it stays at the recalled level")
end)

test("a waiting bookmark's blink reaches the position page's grid and leaves another page's LEDs as they were (#593)", function()
  local context, S, device = bar_wait_grid()
  local other = context.grid.plug(2, 16, 16)
  S.lib.grid_core.set_page(2, 1)
  context.clock.run_for(0.5)
  local before = snapshot(other)
  local seen = {}
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  for _ = 1, 15 do
    context.clock.run_for(1 / 15)
    seen[key_led(device, 1, 2)] = true
  end
  local LEVELS = S.lib.positions.LEVELS
  assert_true(seen[LEVELS.waiting_high] and seen[LEVELS.waiting_low], "the page-5 grid's key blinks")
  assert_equal(snapshot(other), before, "the page-1 grid shows what it showed before the wait")
end)

test("a second key moves the waiting mark on the grid (#593)", function()
  local context, S, device = bar_wait_grid()
  local LEVELS = S.lib.positions.LEVELS
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  context.clock.run_for(0.5)
  S.lib.positions.strip_key(1, 1, 4, 1); S.lib.positions.strip_key(1, 1, 4, 0)
  local seen2, seen4 = {}, {}
  for _ = 1, 12 do
    context.clock.run_for(1 / 15)
    seen2[key_led(device, 1, 2)] = true
    seen4[key_led(device, 1, 4)] = true
  end
  assert_true(not seen2[LEVELS.waiting_high] and not seen2[LEVELS.waiting_low], "key 2 no longer blinks")
  assert_equal(key_led(device, 1, 2), LEVELS.bookmark)
  assert_true(seen4[LEVELS.waiting_high] and seen4[LEVELS.waiting_low], "key 4 does")
end)

test("two voices' waiting bookmarks blink, and one landing leaves the other blinking (#593)", function()
  local context, S, device = bar_wait_grid()
  local LEVELS = S.lib.positions.LEVELS
  S.buffers[2].seconds = 16
  params:set("v2_source", S.constants.SOURCE_SYNTH + 2)
  params:set("quantize_actions", 2)  -- beat
  context.clock.run_for((4.02 - clock.get_beats()) * clock.get_beat_sec())
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  params:set("quantize_actions", 3)  -- bar: voice 2's recall waits longer
  S.lib.positions.strip_key(1, 2, 3, 1); S.lib.positions.strip_key(1, 2, 3, 0)
  assert_equal(S.lib.positions.waiting_bookmark(1), 2)
  assert_equal(S.lib.positions.waiting_bookmark(2), 3)
  local one, two = {}, {}
  for _ = 1, 6 do
    context.clock.run_for(1 / 15)
    one[key_led(device, 1, 2)] = true
    two[key_led(device, 2, 3)] = true
  end
  assert_true(one[LEVELS.waiting_high] and one[LEVELS.waiting_low], "voice 1's key blinks")
  assert_true(two[LEVELS.waiting_high] and two[LEVELS.waiting_low], "voice 2's key blinks")
  context.clock.run_for((5.05 - clock.get_beats()) * clock.get_beat_sec())
  assert_equal(S.lib.positions.waiting_bookmark(1), nil, "voice 1's recall landed on the beat")
  assert_equal(S.lib.positions.waiting_bookmark(2), 3, "voice 2's still waits for the bar")
  local after = {}
  for _ = 1, 8 do
    context.clock.run_for(1 / 15)
    after[key_led(device, 2, 3)] = true
  end
  assert_true(after[LEVELS.waiting_high] and after[LEVELS.waiting_low], "voice 2's key goes on blinking")
  assert_equal(key_led(device, 1, 2), LEVELS.recalled, "voice 1's key shows its landing")
end)

test("a wait repaints nothing while no grid shows the position page (#593)", function()
  local context, S, device = bar_wait_grid()
  S.lib.grid_core.set_page(1, 1)
  context.clock.run_for(0.5)
  local before = device.refresh_count
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  context.clock.run_for(1)
  assert_equal(device.refresh_count, before, "a grid on page 1 is not repainted for the wait")
end)

test("with quantize actions off nothing ever shows as waiting (#593)", function()
  local context, S, device = bar_wait_grid()
  params:set("quantize_actions", 1)
  local LEVELS = S.lib.positions.LEVELS
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  for _ = 1, 20 do
    context.clock.run_for(1 / 15)
    for n = 1, 4 do
      local level = S.lib.positions.strip_level(1, n)
      assert_true(level ~= LEVELS.waiting_high and level ~= LEVELS.waiting_low, "key " .. n .. " at " .. level)
    end
  end
end)

end

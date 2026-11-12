-- test/unit/grid_layout_64_test.lua
-- The 8x8 grid layout (lib/grid/layout_64.lua): one half of the patterns at
-- a time, row 8's play / half key and voice toggles
-- Run alone: lua test/run.lua grid_layout_64

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function grid_core() return local_value("S").lib.grid_core end
local function shown_half(port) return grid_core().port_state(port).half or 1 end
local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end
-- hold (1,8) past the half-toggle time, then let go
local function switch_half(context, port)
  context.grid.press(port, 1, 8, 1)
  context.clock.run_for(0.51)
  context.grid.press(port, 1, 8, 0)
end

-- #449: the distinct keys the layout is handed at press, per view (a half or the positions view), from
-- now on (view(port) names it), and how many there are
local function record_presses(layout_name, view)
  local layout = local_value("S").registry.grid_layouts[layout_name]
  local real_key, pressed = layout.key, {}
  layout.key = function(port, x, y, z)
    if z == 1 then
      local shown = view(port)
      pressed[shown] = pressed[shown] or {}
      pressed[shown][x .. "," .. y] = true
    end
    return real_key(port, x, y, z)
  end
  return pressed
end
local function key_count(keys)
  local count = 0
  for _ in pairs(keys or {}) do count = count + 1 end
  return count
end

-- 2b's step editor (S.lib.pages_seq), as a double until it lands: the four
-- functions the grid calls, shaped as 2b gives them (open_step_editor(voice,
-- step, port) returns true, close_step_editor(port), step_editor() returns
-- {voice, step, port} or nil, step_editor_edited() a boolean). Open pushes
-- a modal owner and close pops it, as the real editor does; editor.calls
-- records each call. Install it after load_strata, in every test that holds
-- a step key 0.3 s
local function step_editor_double()
  local S = local_value("S")
  local editor = {open = nil, edited = false, calls = {}}
  local owner = {draw = function() end}
  local seq = S.lib.pages_seq
  function seq.open_step_editor(voice, step, port)
    table.insert(editor.calls, "open " .. voice .. " " .. step .. " " .. port)
    if editor.open then S.lib.ui_modal.pop(owner) end
    editor.open, editor.edited = {voice = voice, step = step, port = port}, false
    S.lib.ui_modal.push(owner)
    return true
  end
  function seq.close_step_editor(port)
    table.insert(editor.calls, "close " .. port)
    if editor.open and editor.open.port == port then
      editor.open = nil
      S.lib.ui_modal.pop(owner)
    end
  end
  function seq.step_editor() return editor.open end
  function seq.step_editor_edited() return editor.edited end
  return editor
end


test("every 64 grid key runs without error", function()
  local context = load_strata()
  local device = context.grid.plug(1, 8, 8)
  local pressed = record_presses("64", function(port)
    return grid_core().page(port) == 5 and "positions" or "half " .. shown_half(port)
  end)
  local S = local_value("S")
  local jumps = 0
  local real_jump = S.lib.positions.jump
  S.lib.positions.jump = function(...) jumps = jumps + 1; return real_jump(...) end
  -- steps 1-8, steps 9-16 and the positions view, each set before every key
  -- (a key may move the view), with the grid voice (1) on buffer 1 holding 16 s
  local views = { { page = 1, half = 1 }, { page = 1, half = 2 }, { page = 5, half = 1 } }
  for _, view in ipairs(views) do
    S.buffers[1].seconds = 16; S.buffers[1].loaded = true
    params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
    select_grid_voice(1)
    for y = 1, 8 do
      for x = 1, 8 do
        grid_core().set_page(1, view.page)
        grid_core().port_state(1).half = view.half
        context.grid.press(1, x, y, 1)
        context.grid.press(1, x, y, 0)
        context.clock.advance()
      end
    end
  end
  assert_true(jumps > 0, "the positions view's keys reached the buffer voice")
  for _, view in ipairs({ "half 1", "half 2", "positions" }) do
    assert_equal(key_count(pressed[view]), 64, view .. ": all 64 keys pressed")
  end
  assert_true(device.refresh_count > 0, "64 grid was redrawn")
end)

test("grid_redraw draws the 64 layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 8, 8)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "64 redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 8 do
    for y = 1, 8 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "64 layout drew something")
end)

test("64 row 8 columns 2-8 toggle voices 1-7", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local voices = local_value("voices")
  for voice_idx = 1, 7 do
    local was_active = voices[voice_idx].active
    tap(context, 1, voice_idx + 1, 8)
    assert_true(voices[voice_idx].active ~= was_active, "(" .. (voice_idx + 1) .. ",8) toggles voice " .. voice_idx)
    assert_equal(device:get_led(voice_idx + 1, 8), voices[voice_idx].active and 12 or 2,
      "voice " .. voice_idx .. " LED (the shared levels, #526)")
  end
  assert_true(voices[7].active, "voice 7 is reachable")
end)

test("64 column 1: a tap plays or stops on release, a 0.5 s hold switches the half", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local patterns = local_value("patterns")
  assert_equal(shown_half(1), 1, "a grid starts on steps 1-8")
  context.grid.press(1, 1, 8, 1)
  assert_true(not local_value("pattern_playing"), "nothing happens at press")
  context.clock.run_for(0.1)
  context.grid.press(1, 1, 8, 0)
  assert_true(local_value("pattern_playing"), "a tap plays on release")
  assert_equal(shown_half(1), 1, "a tap does not switch the half")
  tap(context, 1, 1, 8)
  assert_true(not local_value("pattern_playing"), "a second tap stops")
  context.grid.press(1, 1, 8, 0)
  assert_true(not local_value("pattern_playing"), "a release with no press does nothing")
  -- a hold switches the half and its release does not play
  context.grid.press(1, 1, 8, 1)
  context.clock.run_for(0.51)
  assert_equal(grid_core().port_state(1).half, 2, "a 0.5 s hold shows steps 9-16")
  context.grid.press(1, 1, 8, 0)
  assert_true(not local_value("pattern_playing"), "the hold's release does not toggle play")
  -- half 2: column x is step 8 + x
  tap(context, 1, 3, 1)
  assert_equal(patterns[1][11], 15, "half 2: (3,1) toggles voice 1 step 11")
  assert_equal(patterns[1][3], 0, "step 3 untouched")
  assert_equal(device:get_led(3, 1), 15, "the LED shows step 11")
  -- the step-level gesture uses positions 1-8 of the shown half
  context.grid.press(1, 3, 2, 1); context.grid.press(1, 4, 2, 1)
  assert_equal(patterns[2][11], 8, "held step 11 takes round(4 * 15 / 8) = 8")
  assert_equal(patterns[2][12] + patterns[2][4], 0, "the level key does not toggle")
  context.grid.press(1, 4, 2, 0); context.grid.press(1, 3, 2, 0)
  context.grid.press(1, 5, 3, 1); context.grid.press(1, 8, 3, 1)
  assert_equal(patterns[3][13], 15, "column 8 is the top level")
  context.grid.press(1, 8, 3, 0); context.grid.press(1, 5, 3, 0)
  -- a hold shows positions, the next switches back
  switch_half(context, 1)
  switch_half(context, 1)
  assert_equal(grid_core().port_state(1).half, 1, "a second hold shows steps 1-8")
  tap(context, 1, 3, 1)
  assert_equal(patterns[1][3], 15, "half 1: (3,1) toggles step 3")
  assert_equal(device:get_led(3, 1), 15)
  assert_equal(patterns[1][11], 15, "step 11 keeps playing, unseen")
end)

test("64 halves are per grid and a removed grid's hold switches nothing", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 8, 8); context.grid.plug(2, 8, 8)
  switch_half(context, 1)
  assert_equal(shown_half(1), 2)
  assert_equal(shown_half(2), 1, "the other grid keeps its own half")
  context.grid.press(2, 1, 8, 1)
  context.grid.unplug(2)
  context.clock.run_for(1)
  assert_true(not local_value("pattern_playing"), "no play from a removed grid")
  context.grid.plug(2, 8, 8)
  assert_equal(shown_half(2), 1, "a grid plugged back shows steps 1-8")
  assert_equal(shown_half(1), 2)
  -- cleanup during a hold: nothing fires
  context.grid.press(1, 1, 8, 1)
  cleanup()
  context.clock.run_for(1)
  assert_equal(shown_half(1), 1, "cleanup forgets the half and cancels the hold")
end)

test("64 lights the shown half's playhead and blinks column 1 when the other half plays", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local S = local_value("S")
  assert_equal(device:get_led(1, 8), 4, "stopped: column 1 dim")
  toggle_pattern_step(2, 4)
  -- the transport's 16th and every voice's step (3.4: each row's playhead is its voice's)
  local function sounding(step)
    S.pattern_sounding_step = step
    for voice_idx = 1, S.constants.NUM_VOICES do S.pattern_sounding_steps[voice_idx] = step end
  end
  S.pattern_playing = true
  sounding(4)
  grid_redraw()
  assert_equal(device:get_led(1, 8), 15, "the shown half plays: column 1 at 15")
  assert_equal(device:get_led(4, 2), 15, "the playhead on an active step")
  assert_equal(device:get_led(4, 1), 4, "the playhead on an empty step")
  assert_equal(device:get_led(5, 1), 0, "no playhead past it")
  -- the other half plays: column 1 blinks 12 / 3 with the beat (four steps)
  local levels = {}
  for step = 9, 16 do
    sounding(step)
    grid_redraw()
    levels[#levels + 1] = device:get_led(1, 8)
    for x = 1, 8 do
      assert_true(device:get_led(x, 1) ~= 4, "no playhead in the shown half at step " .. step)
    end
  end
  assert_equal(table.concat(levels, " "), "12 12 12 12 3 3 3 3", "column 1 blinks with the beat")
  -- half 2 shows steps 9-16: the playhead lights there, and half 1's steps blink
  S.pattern_playing = false
  switch_half(context, 1)
  S.pattern_playing = true
  sounding(12)
  grid_redraw()
  assert_equal(device:get_led(4, 1), 4, "half 2: step 12's playhead in column 4")
  assert_equal(device:get_led(1, 8), 15)
  sounding(3)
  grid_redraw()
  assert_equal(device:get_led(1, 8), 12, "half 1 plays: column 1 blinks (beat 1 lit)")
  sounding(6)
  grid_redraw()
  assert_equal(device:get_led(1, 8), 3, "beat 2 dim")
  S.pattern_playing = false
  grid_redraw()
  assert_equal(device:get_led(1, 8), 8, "stopped on half 2: column 1 at 8")
  -- with the sequencer running for real
  pattern_toggle()
  context.clock.advance()
  assert_true(device:get_led(1, 8) == 15 or device:get_led(1, 8) == 12 or device:get_led(1, 8) == 3, "playing")
  pattern_toggle()
end)

test("64 column 1 shows which half is up while the patterns are stopped", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  local other = context.grid.plug(2, 8, 8)
  assert_true(not local_value("pattern_playing"), "stopped")
  assert_equal(device:get_led(1, 8), 4, "steps 1-8: column 1 at 4")
  switch_half(context, 1)
  assert_equal(device:get_led(1, 8), 8, "steps 9-16: column 1 at 8")
  assert_equal(other:get_led(1, 8), 4, "each grid shows its own half")
  switch_half(context, 1)  -- positions (3.3's third view)
  switch_half(context, 1)
  assert_equal(device:get_led(1, 8), 4, "back on steps 1-8: 4 again")
  -- playing, the playhead rules apply in either half; stopping shows the half again
  switch_half(context, 1)
  pattern_toggle()  -- step 1 sounds: the other half
  assert_equal(device:get_led(1, 8), 12, "playing: half 1's beat blinks")
  pattern_toggle()
  assert_equal(device:get_led(1, 8), 8, "stopped on steps 9-16: 8")
  local levels = local_value("S").lib.grid_layout_64.LAYOUT.stopped_levels
  assert_equal(levels[1], 4); assert_equal(levels[2], 8)
end)

test("64 lights the sounding step between steps, in its own half (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 8, 8)
  S.patterns[1][8] = 9
  pattern_toggle()  -- step 1 plays at once
  grid_redraw()
  assert_equal(device:get_led(1, 2), 4, "just started: step 1 is the playhead")
  assert_equal(device:get_led(1, 8), 15, "and it is in the shown half")
  for _ = 2, 8 do h.wake(context, "pattern_clock") end  -- steps 2-8 play; the position is now 9
  grid_redraw()  -- a redraw between steps (a key press)
  assert_equal(S.pattern_position, 9)
  assert_equal(device:get_led(8, 1), 15, "step 8 sounds: column 8 lit")
  assert_equal(device:get_led(1, 8), 15, "the playhead is still in the shown half, no blink")
  -- half 2 shows steps 9-16: step 8 sounding is the other half
  S.lib.grid_core.port_state(1).half = 2
  grid_redraw()
  for x = 1, 8 do
    assert_true(device:get_led(x, 2) ~= 4, "half 2: no playhead while step 8 sounds (column " .. x .. ")")
  end
  assert_equal(device:get_led(1, 8), 3, "half 1 plays: column 1 blinks (step 8 is beat 2)")
  h.wake(context, "pattern_clock")  -- step 9 plays
  assert_equal(device:get_led(1, 2), 4, "half 2: step 9 in column 1")
  assert_equal(device:get_led(1, 8), 15)
  for _ = 10, PATTERN_LENGTH + 1 do h.wake(context, "pattern_clock") end  -- through 16, wrap to 1
  grid_redraw()
  assert_equal(S.lib.sequencer.sounding_step(), 1, "wrapped to step 1")
  assert_equal(device:get_led(1, 8), 12, "half 1 plays again: column 1 blinks (beat 1)")
  pattern_toggle()
  assert_equal(device:get_led(1, 8), 8, "stopped on steps 9-16: column 1 at 8")
end)


-- Voice 1 and 3 on slot 1 (16 s); the 64 grid on port 1
local function positions_grid()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  for voice_idx = 1, 3 do params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1) end
  local device = context.grid.plug(1, 8, 8)
  return context, S, device
end

test("64: row 8 column 1's hold cycles steps 1-8, steps 9-16 and positions", function()
  local context, S, device = positions_grid()
  local core = grid_core()
  assert_equal(core.page(1), 1, "starts on the steps")
  switch_half(context, 1)
  assert_equal(shown_half(1), 2, "steps 9-16"); assert_equal(core.page(1), 1)
  switch_half(context, 1)
  assert_equal(core.page(1), 5, "positions is page 5")
  switch_half(context, 1)
  assert_equal(core.page(1), 1, "back to the steps"); assert_equal(shown_half(1), 1, "steps 1-8")
  switch_half(context, 1); switch_half(context, 1)
  assert_equal(core.page(1), 5, "positions again")
  S.pattern_playing = false
  tap(context, 1, 1, 8)
  assert_true(S.pattern_playing, "a tap still plays in the positions view")
  grid_redraw()
  assert_equal(device:get_led(1, 8), 15, "positions view: playing is 15")
  tap(context, 1, 1, 8)
  assert_true(not S.pattern_playing, "and stops")
  grid_redraw()
  assert_equal(device:get_led(1, 8), 6, "positions view: stopped is 6")
end)

test("64: rows 1-2 are the grid voice's 16 positions and a pair may span both", function()
  local context, S = positions_grid()
  grid_core().set_page(1, 5)
  S.grid_voice_select = 1
  params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)
  tap(context, 1, 5, 1)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "cell 5 of 16")
  tap(context, 1, 1, 2)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "row 2 column 1 is cell 9")
  context.grid.press(1, 8, 1, 1)
  context.grid.press(1, 1, 2, 1)
  context.grid.press(1, 1, 2, 0); context.grid.press(1, 8, 1, 0)
  assert_near(params:get("v1_loop_start"), 0.4375, 1e-9, "cells 8-9")
  assert_near(params:get("v1_loop_length"), 0.125, 1e-6, "two cells")
end)

test("64: a synth voice's strip is dark and stores nothing (#445)", function()
  local context, S, device = positions_grid()
  grid_core().set_page(1, 5)
  S.grid_voice_select = 1
  params:set("v1_source", 1)
  grid_redraw()
  for x = 1, 8 do assert_equal(device:get_led(x, 3), 0, "strip column " .. x) end
  context.grid.press(1, 6, 3, 1)
  context.grid.press(1, 2, 3, 1)
  assert_equal(device:get_led(6, 3), 0, "store held: dark")
  assert_equal(device:get_led(2, 3), 0, "the pressed bookmark: dark")
  assert_equal(params:get("v1_bookmark_2"), 0.25, "and the bookmark keeps its value")
  context.grid.press(1, 2, 3, 0); context.grid.press(1, 6, 3, 0)
end)

test("64: row 3 is the strip and row 7 picks the grid voice", function()
  local context, S, device = positions_grid()
  local positions = S.lib.positions
  grid_core().set_page(1, 5)
  S.grid_voice_select = 1
  params:set("v1_bookmark_2", 0.6)
  tap(context, 1, 2, 3)
  assert_equal(positions.last_recalled(1), 2, "bookmark 2 recalled")
  params:set("v1_buf_pos", 0.3)
  context.grid.press(1, 6, 3, 1); tap(context, 1, 3, 3); context.grid.press(1, 6, 3, 0)
  assert_near(positions.bookmark(1, 3), 0.3, 1e-6, "bookmark 3 stored")
  context.grid.press(1, 7, 3, 1)
  assert_true(positions.scan_held(1), "hold on")
  context.grid.press(1, 7, 3, 0)
  assert_true(not positions.scan_held(1), "hold off")
  params:set("v1_loop_length", 0.5)
  tap(context, 1, 8, 3)
  assert_near(params:get("v1_loop_start"), 0, 1e-9, "whole loop start")
  assert_near(params:get("v1_loop_length"), 1, 1e-6, "whole loop length")
  tap(context, 1, 3, 7)
  assert_equal(S.grid_voice_select, 3, "row 7 column 3 picks voice 3")
  grid_redraw()
  assert_equal(device:get_led(3, 7), 15, "selected")
  assert_equal(device:get_led(1, 7), 6, "a buffer voice")
  params:set("v2_source", S.constants.SOURCE_SYNTH)
  grid_redraw()
  assert_equal(device:get_led(2, 7), 2, "another voice")
  for y = 4, 6 do for x = 1, 8 do assert_equal(device:get_led(x, y), 0, "rows 4-6 dark") end end
end)

-- #239: store belongs to the port while its key is down
test("64: store held, the grid voice changed: a bookmark press stores for the voice shown", function()
  local context, S, device = positions_grid()
  local positions = S.lib.positions
  grid_core().set_page(1, 5)
  S.grid_voice_select = 1
  if S.voices[2].active then toggle_voice(2) end
  assert_true(not S.voices[2].active, "voice 2 stopped")
  params:set("v2_buf_pos", 0.4)
  local v1_bookmark = params:get("v1_bookmark_1")
  context.grid.press(1, 6, 3, 1)
  tap(context, 1, 2, 7)
  assert_equal(S.grid_voice_select, 2, "row 7 column 2 picks voice 2")
  context.grid.press(1, 1, 3, 1)
  assert_near(params:get("v2_bookmark_1"), 0.4, 1e-6, "voice 2's buf_pos is stored")
  assert_near(params:get("v2_buf_pos"), 0.4, 1e-9, "no recall: buf_pos unchanged")
  assert_equal(positions.last_recalled(2), nil, "nothing recalled")
  assert_near(params:get("v1_bookmark_1"), v1_bookmark, 1e-9, "voice 1's bookmark unchanged")
  grid_redraw()
  assert_equal(device:get_led(6, 3), 15, "store lit while held")
  assert_equal(device:get_led(1, 3), 15, "the stored bookmark lit while held")
  context.grid.press(1, 1, 3, 0)
  context.grid.press(1, 6, 3, 0)
  params:set("v2_buf_pos", 0.7)
  tap(context, 1, 1, 3)
  assert_near(params:get("v2_buf_pos"), 0.4, 1e-6, "store up: a press recalls the bookmark")
  assert_equal(positions.last_recalled(2), 1)
end)

test("64: the step views keep every key", function()
  local context, S = positions_grid()
  local calls = 0
  local positions = S.lib.positions
  local originals = {grid_key = positions.grid_key, strip_key = positions.strip_key}
  positions.grid_key = function(...) calls = calls + 1 end
  positions.strip_key = function(...) calls = calls + 1 end
  for half = 1, 2 do
    if shown_half(1) ~= half then switch_half(context, 1) end
    for y = 1, 8 do
      for x = 1, 8 do
        if not (x == 1 and y == 8) then tap(context, 1, x, y) end
      end
    end
  end
  positions.grid_key, positions.strip_key = originals.grid_key, originals.strip_key
  assert_equal(calls, 0, "the step views never reach positions")
end)

test("64: the positions view is per port", function()
  local context = positions_grid()
  context.grid.plug(2, 8, 8)
  switch_half(context, 1); switch_half(context, 1)
  assert_equal(grid_core().page(1), 5, "port 1 shows positions")
  assert_equal(grid_core().page(2), 1, "port 2 stays on its steps")
  switch_half(context, 2)
  assert_equal(grid_core().page(2), 1); assert_equal(shown_half(2), 2, "port 2 switches its own half")
  assert_equal(grid_core().page(1), 5)
end)

test("64: a position key whose release comes after the view switched leaks nothing", function()
  local context, S = positions_grid()
  local positions = S.lib.positions
  grid_core().set_page(1, 5)
  S.grid_voice_select = 1
  params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)
  context.grid.press(1, 7, 3, 1)  -- scan hold down
  assert_true(positions.scan_held(1), "held")
  context.grid.press(1, 8, 1, 1)  -- a loop anchor
  switch_half(context, 1)         -- the view leaves positions
  assert_equal(grid_core().page(1), 1)
  context.grid.press(1, 7, 3, 0); context.grid.press(1, 8, 1, 0)
  positions.end_stale_holds()
  assert_true(not positions.scan_held(1), "no stuck scan hold")
  context.grid.press(1, 1, 2, 1); context.grid.press(1, 1, 2, 0)
  assert_near(params:get("v1_loop_length"), 1, 1e-9, "no stale anchor made a loop")
end)

test("64: a hold in the step views keeps working and never reaches positions", function()
  local context, S = positions_grid()
  local calls = 0
  local original = S.lib.positions.strip_key
  local editor = step_editor_double()
  S.lib.positions.strip_key = function() calls = calls + 1 end
  context.grid.press(1, 3, 2, 1)
  context.clock.run_for(0.6)
  context.grid.press(1, 3, 2, 0)
  context.grid.press(1, 6, 3, 1); context.clock.run_for(0.6); context.grid.press(1, 6, 3, 0)
  S.lib.positions.strip_key = original
  assert_equal(calls, 0, "no strip call from the step views")
  assert_equal(table.concat(editor.calls, ","), "open 2 3 1,close 1,open 3 6 1,close 1", "each hold opened the step editor")
end)

test("switching halves ends a held step gesture", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 8, 8)
  step_editor_double()
  context.grid.press(1, 3, 1, 1)  -- half 1: voice 1 step 3 held
  assert_equal(patterns[1][3], 0, "step 3 toggles at its release, not its press")
  context.grid.press(1, 1, 8, 1); context.clock.run_for(0.6); context.grid.press(1, 1, 8, 0)
  assert_equal(shown_half(1), 2, "the hold showed steps 9-16")
  tap(context, 1, 8, 1)
  assert_equal(patterns[1][16], 15, "column 8 now toggles step 16")
  assert_equal(patterns[1][3], 0, "the hidden held step takes no level")
  context.grid.press(1, 3, 1, 0)
  assert_equal(patterns[1][3] + patterns[1][11], 0, "and its release toggles nothing, in either half")
end)

test("end_port_step_gestures ignores a port that is not a grid port (nil and NaN raise nothing)", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local S = local_value("S")
  context.grid.plug(1, 8, 8)
  context.grid.press(1, 3, 1, 1)  -- voice 1 step 3 held: on at 15
  local before = {}
  for key in pairs(S.grid_held) do before[#before + 1] = key end
  local core = grid_core()
  core.end_port_step_gestures(nil)
  core.end_port_step_gestures(0 / 0)
  for _, port in ipairs({0, 1.5, S.MAX_GRID_PORTS + 1, "1", -1}) do
    core.end_port_step_gestures(port)
  end
  local after = {}
  for key in pairs(S.grid_held) do after[#after + 1] = key end
  assert_equal(#after, #before, "no port entry made")
  context.grid.press(1, 4, 1, 1)
  assert_equal(patterns[1][3], 8, "port 1's held step still takes the level (4 * 15 / 8 = 7.5 -> 8)")
  assert_equal(patterns[1][4], 0, "the level key does not toggle")
end)

-- 3.4 (design §8.7, §11): a held step opens the step editor in the steps
-- views, for the step of the half shown; the positions view never does
test("a held step opens the step editor in the steps views", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local editor = step_editor_double()
  local patterns = local_value("patterns")
  context.grid.plug(1, 8, 8)
  context.grid.press(1, 3, 2, 1); context.clock.run_for(0.35)
  assert_equal(table.concat(editor.calls, ","), "open 2 3 1", "steps 1-8: voice 2's step 3")
  context.grid.press(1, 3, 2, 0)
  assert_equal(editor.open, nil, "the release closes it")
  assert_equal(patterns[2][3], 0, "and toggles nothing")
  switch_half(context, 1)
  context.grid.press(1, 3, 2, 1); context.clock.run_for(0.35)
  assert_equal(editor.calls[#editor.calls], "open 2 11 1", "steps 9-16: voice 2's step 11")
  assert_true(S.lib.ui_modal.top() ~= nil, "the editor has the screen")
  -- the half switch ends the held step: the editor closes, nothing toggles
  switch_half(context, 1)
  assert_equal(grid_core().page(1), 5, "the hold went on to the positions view")
  assert_equal(editor.open, nil, "the editor closed with the half")
  assert_equal(S.lib.ui_modal.top(), nil)
  context.grid.press(1, 3, 2, 0)
  assert_equal(patterns[2][11], 0, "its release toggles nothing")
  local opened = #editor.calls
  context.grid.press(1, 3, 1, 1); context.clock.run_for(0.35); context.grid.press(1, 3, 1, 0)
  assert_equal(#editor.calls, opened, "the positions view opens no editor")
  -- a tap still toggles, on its release
  switch_half(context, 1)
  context.grid.press(1, 5, 4, 1)
  assert_equal(patterns[4][5], 0, "a press leaves voice 4's step 5")
  context.grid.press(1, 5, 4, 0)
  assert_equal(patterns[4][5], 15, "its release toggles it")
end)

-- (mute) design §8.14: a silenced running voice's key lights at 6
test("a silenced voice's key lights at 6 on every layout", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 8)
  toggle_voice(3)
  assert_equal(device:get_led(4, 8), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(4, 8), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0); params:set("v4_solo", 1)
  assert_equal(device:get_led(4, 8), 6, "silenced by voice 4's solo: 6")
end)

end

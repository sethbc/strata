-- test/unit/grid_layout_128h_test.lua
-- The 16x8 grid layout (lib/grid/layout_128h.lua)
-- Run alone: lua test/run.lua grid_layout_128h

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end

local function grid_core() return local_value("S").lib.grid_core end

local function pattern_sum(patterns)
  local sum = 0
  for voice_idx = 1, #patterns do
    for step = 1, #patterns[voice_idx] do sum = sum + patterns[voice_idx][step] end
  end
  return sum
end

-- #449: the distinct keys the layout is handed at press, per grid page, from
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

test("every 128h grid key on every page runs without error", function()
  local context = load_strata()
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 8)
  local pressed = record_presses("128h", function(port) return grid_core().page(port) end)
  local jumps = 0
  local real_jump = S.lib.positions.jump
  S.lib.positions.jump = function(...) jumps = jumps + 1; return real_jump(...) end
  -- all five pages, each key pressed on its page (set before every key: row
  -- 8's page keys move it), with voice 1 on buffer 1 holding 16 s
  for page = 1, 5 do
    S.buffers[1].seconds = 16; S.buffers[1].loaded = true
    params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
    for y = 1, 8 do
      for x = 1, 16 do
        grid_core().set_page(1, page)
        assert_equal(grid_core().page(1), page, "the sweep is on page " .. page)
        context.grid.press(1, x, y, 1)
        context.grid.press(1, x, y, 0)
        context.clock.advance()
      end
    end
  end
  for page = 1, 5 do assert_equal(key_count(pressed[page]), 128, "page " .. page .. ": all 128 keys pressed") end
  assert_true(jumps > 0, "page 5's position keys reached the buffer voice")
  assert_true(device.refresh_count > 0, "128h grid was redrawn")
end)

test("grid_redraw draws the 128h layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 16, 8)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "128h redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 16 do
    for y = 1, 8 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "128h layout drew something")
end)

test("play/stop columns 1-4 on row 8 all light with the state (16x8)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 8)
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 4, "8 rows: play column " .. x .. " dim when stopped")
  end
  context.grid.press(1, 4, 8, 1)  -- column 4 starts the pattern
  assert_true(local_value("pattern_playing"), "column 4 plays")
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 15, "8 rows: play column " .. x .. " lit while playing")
  end
  context.grid.press(1, 3, 8, 1)  -- column 3 stops it
  for x = 1, 4 do
    assert_equal(device:get_led(x, 8), 4, "8 rows: play column " .. x .. " dim after stop")
  end
end)

test("128h row 8 columns 5-8 pick pages 1-4 and light the shown one", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  for page = 1, 4 do
    tap(context, 1, 4 + page, 8)
    assert_equal(grid_core().page(1), page, "column " .. (4 + page) .. " shows page " .. page)
    for column = 5, 8 do
      assert_equal(device:get_led(column, 8), column - 4 == page and 15 or 2,
        "page " .. page .. ": row 8 column " .. column .. " (the shared page levels, #526)")
    end
  end
end)

test("128h page 2: four faders, the page selector, voice select and lock", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local frozen = local_value("frozen")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 6, 8)  -- page 2
  local before = pattern_sum(patterns)

  -- rows 1-4: faders 1-4 of voice 1's fader page 1
  local ids = fader_param_ids(1)
  tap(context, 1, 16, 1)
  assert_equal(fader_position(ids[1]), 16, "column 16 sets fader 1 to its maximum")
  local _, max_value = param_range(ids[1])
  assert_near(params:get(ids[1]), max_value, 1e-6, "fader 1 at the maximum")
  assert_equal(device:get_led(16, 1), 15, "fader 1 shows its value at column 16")
  assert_equal(device:get_led(15, 1), 8, "the bar below the value")
  tap(context, 1, 1, 2)
  assert_equal(fader_position(ids[2]), 1, "column 1 sets fader 2 to its minimum")
  tap(context, 1, 8, 3)
  assert_equal(fader_position(ids[3]), 8, "column 8 on fader 3")
  assert_equal(device:get_led(8, 3), 15, "value column bright")
  assert_equal(device:get_led(7, 3), 8, "bar below the value")
  assert_equal(device:get_led(9, 3), 0, "nothing above the value")
  tap(context, 1, 5, 4)
  assert_equal(fader_position(ids[4]), 5, "row 4 is fader 4")
  assert_equal(pattern_sum(patterns), before, "rows 1-7 never toggle steps on page 2")

  -- row 5: the fader page selector, only up to fader_page_count; column
  -- 16 is 3.4's macro page key (4 on the voice faders)
  local pages = fader_page_count(1)
  for x = 1, 16 do
    local expected = x == 1 and 15 or ((x <= pages or x == 16) and 4 or 0)
    assert_equal(device:get_led(x, 5), expected, "row 5 column " .. x)
  end
  tap(context, 1, 3, 5)
  assert_equal(local_value("param_page"), 3, "row 5 column 3 picks fader page 3")
  assert_equal(device:get_led(3, 5), 15, "page 3 lit")
  assert_equal(device:get_led(1, 5), 4, "page 1 dim")
  tap(context, 1, 16, 2)
  assert_equal(fader_position(ids[10]), 16, "row 2 on fader page 3 is fader 10")
  tap(context, 1, pages + 1, 5)
  assert_equal(local_value("param_page"), 3, "a column past the last fader page does nothing")

  -- row 6, columns 1-7: voice select (selected 15, others 4)
  tap(context, 1, 2, 6)
  assert_equal(local_value("grid_voice_select"), 2, "row 6 column 2 selects voice 2")
  for x = 1, 16 do
    local expected = x == 2 and 15 or (x <= 7 and 4 or 0)
    assert_equal(device:get_led(x, 6), expected, "row 6 column " .. x)
  end
  local voice2_ids = fader_param_ids(2)
  local fader_index = (local_value("param_page") - 1) * 4 + 1
  tap(context, 1, 1, 1)
  assert_equal(fader_position(voice2_ids[fader_index]), 1, "the faders follow the selected voice")
  tap(context, 1, 8, 6)
  assert_equal(local_value("grid_voice_select"), 2, "row 6 column 8 does nothing")

  -- row 7, columns 1-7: lock (12 locked, 2 not)
  tap(context, 1, 3, 7)
  assert_true(frozen[3], "row 7 column 3 locks voice 3")
  for x = 1, 16 do
    local expected = x == 3 and 12 or (x <= 7 and 2 or 0)
    assert_equal(device:get_led(x, 7), expected, "row 7 column " .. x)
  end
  tap(context, 1, 3, 7)
  assert_true(not frozen[3], "a second press unlocks")
  tap(context, 1, 9, 7)
  for i = 1, 7 do assert_true(not frozen[i], "row 7 column 9 locks nothing") end
  assert_equal(pattern_sum(patterns), before, "no page 2 key toggled a step")
end)

test("128h column 16 of row 8 cycles the voice and page 2 shows it", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 16, 8)
  assert_equal(local_value("grid_voice_select"), 2, "column 16 selects the next voice")
  tap(context, 1, 6, 8)  -- page 2
  assert_equal(device:get_led(2, 6), 15, "page 2 shows voice 2 selected")
  assert_equal(device:get_led(1, 6), 4)
  local ids = fader_param_ids(2)
  assert_equal(device:get_led(fader_position(ids[1]), 1), 15, "row 1 shows voice 2's first fader")
  for _ = 1, 6 do tap(context, 1, 16, 8) end
  assert_equal(local_value("grid_voice_select"), 1, "the cycle wraps from voice 7 to voice 1")
  assert_equal(device:get_led(1, 6), 15, "page 2 follows the cycle")
end)

test("128h page 4 sets sources and records and clears slots", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 8, 8)  -- page 4
  assert_equal(grid_core().page(1), 4, "row 8 column 8 shows page 4")
  local before = pattern_sum(patterns)

  -- rows 1-7, columns 1-10: each voice's source
  tap(context, 1, 3, 2)
  assert_equal(params:get("v2_source"), 3, "row 2 column 3: voice 2 reads buf 2")
  tap(context, 1, 10, 7)
  assert_equal(params:get("v7_source"), 10, "row 7 column 10: voice 7 reads the input")
  assert_equal(pattern_sum(patterns), before, "source keys never toggle steps")

  -- rows 1-2, columns 13-16: record slots 1-4 and 5-8
  context.clear_engine_calls()
  tap(context, 1, 13, 1)
  assert_equal(context.calls_named("recordBuffer")[1].args[1], 0, "(13,1) records slot 1")
  tap(context, 1, 16, 2)
  assert_equal(context.calls_named("recordBuffer")[2].args[1], 7, "(16,2) records slot 8")
  assert_equal(device:get_led(13, 1), 15, "slot 1 recording")
  assert_equal(device:get_led(16, 2), 15, "slot 8 recording")

  -- rows 3-4, columns 13-16: clear slots 1-4 and 5-8
  tap(context, 1, 14, 3)
  assert_equal(context.calls_named("clearBuffer")[1].args[1], 1, "(14,3) clears slot 2")
  tap(context, 1, 15, 4)
  assert_equal(context.calls_named("clearBuffer")[2].args[1], 6, "(15,4) clears slot 7")

  -- column 11 and rows 5-7 of columns 13-16 do nothing (column 12 is freeze)
  context.clear_engine_calls()
  for y = 1, 7 do
    tap(context, 1, 11, y)
  end
  for y = 5, 7 do
    for x = 13, 16 do tap(context, 1, x, y) end
  end
  assert_equal(#context.engine_calls, 0, "keys outside the source and slot blocks send nothing")
end)

test("128h page 4 LEDs come from source_level, record_level and CLEAR_LEVEL", function()
  local context = load_strata(); finish_startup(context)
  local core = grid_core()
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 8, 8)  -- page 4
  load_buffer(2, "/tmp/a.wav")                                    -- slot 2 holds audio
  params:set("record_duration", 2); params:set("buf6_record", 1)  -- slot 6 records
  params:set("v1_source", 3)                                      -- voice 1 on buf 2
  params:set("v4_source", 9)                                      -- voice 4 on an empty buf 8
  for voice_idx = 1, 7 do
    for x = 1, 10 do
      assert_equal(device:get_led(x, voice_idx), core.source_level(voice_idx, x),
        "voice " .. voice_idx .. " source column " .. x)
    end
    assert_equal(device:get_led(11, voice_idx), voice_idx == 1 and 15 or 0, "column 11 marks the grid voice, 1 (#444)")
    assert_equal(device:get_led(12, voice_idx), 3, "column 12 the freeze key (not frozen: 3)")
  end
  assert_equal(device:get_led(9, 4), 15, "the selected empty buffer lights 15")
  for slot = 1, 8 do
    local x = 12 + (slot - 1) % 4 + 1
    local record_row = slot <= 4 and 1 or 2
    assert_equal(device:get_led(x, record_row), core.record_level(slot), "record slot " .. slot)
    assert_equal(device:get_led(x, record_row + 2), core.CLEAR_LEVEL, "clear slot " .. slot)
  end
  assert_equal(device:get_led(14, 1), 8, "slot 2 holding audio")
  assert_equal(device:get_led(14, 2), 15, "slot 6 recording")
  assert_equal(device:get_led(13, 1), 2, "slot 1 empty")
  -- rows 5-6 hold the grid voice's strip now; the rest stays dark
  for x = 13, 16 do assert_equal(device:get_led(x, 7), 0, "row 7 of columns 13-16 dark") end
  assert_equal(device:get_led(16, 6), 0, "column 16 of row 6 dark")
  -- a change made elsewhere reaches the LEDs
  clear_buffer(2)
  assert_equal(device:get_led(14, 1), 2, "a cleared slot dims")
  -- row 8 keeps its meaning on page 4
  tap(context, 1, 1, 8)
  assert_true(local_value("pattern_playing"), "row 8 plays on page 4")
  assert_equal(device:get_led(8, 8), 15, "row 8 shows page 4")
end)

test("128h scene saves need a hold", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 7, 8)  -- page 3
  assert_equal(device:get_led(4, 3), 4, "save key idle")
  context.grid.press(1, 4, 3, 1)
  assert_equal(device:get_led(4, 3), 15, "a pending save lights at 15")
  context.clock.run_for(0.4)
  context.grid.press(1, 4, 3, 0)
  assert_true(not scenes[4].populated, "released early: nothing saved")
  assert_equal(device:get_led(4, 3), 4, "the release dims the key")
  context.grid.press(1, 4, 3, 1)
  context.clock.run_for(0.51)
  assert_true(scenes[4].populated, "held 0.5 s: saved")
  assert_equal(device:get_led(4, 1), 8, "row 1 shows the saved scene")
  context.grid.press(1, 4, 3, 0)
end)

-- #452: the scene keys show the core's levels (grid_core_test.lua holds
-- the rule: the next slot, the current scene, the blink)
test("128h page 3: the scene keys show the core's levels (#452)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  local core = grid_core()
  tap(context, 1, 7, 8)  -- page 3
  capture_scene(1); capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 4)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)  -- scene 1 playing, scene 2 next
  context.grid.press(1, 5, 3, 1)
  local seen = {}
  for i = 1, 8 do
    assert_equal(device:get_led(i, 1), core.scene_recall_level(i), "recall key " .. i)
    assert_equal(device:get_led(i, 2), core.scene_fade_level(i), "fade key " .. i)
    assert_equal(device:get_led(i, 3), core.scene_save_level(1, i, 3), "save key " .. i)
    seen[device:get_led(i, 1)] = true
  end
  assert_true(seen[15] and seen[10] and seen[8] and seen[2], "the recall keys show all four levels")
  assert_equal(core.scene_save_level(1, 5, 3), 15, "scene 5's save is pending")
  context.grid.press(1, 5, 3, 0)
  params:set("scene_sequencer_enabled", 0)
end)

test("two 128h grids keep their own pages", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8); context.grid.plug(2, 16, 8)
  tap(context, 1, 8, 8)  -- grid 1 on page 4, grid 2 on page 1
  tap(context, 2, 3, 2)
  assert_equal(patterns[2][3], 15, "grid 2's key toggles a step")
  assert_equal(params:get("v2_source"), 1, "and sets no source")
  tap(context, 1, 3, 2)
  assert_equal(params:get("v2_source"), 3, "grid 1's key sets the source")
  assert_equal(patterns[2][3], 15, "and toggles no step")
end)

test("128h page 4 column 12 toggles freeze", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 8)
  tap(context, 1, 8, 8)  -- page 4
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(device:get_led(12, voice_idx), 3, "voice " .. voice_idx .. " not frozen: 3")
    tap(context, 1, 12, voice_idx)
    assert_equal(params:get("v" .. voice_idx .. "_freeze"), 1, "column 12 row " .. voice_idx .. " freezes it")
    assert_equal(device:get_led(12, voice_idx), 15, "frozen: 15")
    assert_equal(params:get("v" .. voice_idx .. "_source"), S.constants.SOURCE_SYNTH, "the source is left alone")
  end
  tap(context, 1, 12, 4)
  assert_equal(params:get("v4_freeze"), 0, "a second press unfreezes")
  assert_equal(device:get_led(12, 4), 3)
  params:set("v4_freeze", 1)
  assert_equal(device:get_led(12, 4), 15, "a param change redraws the grid")
  -- the slot keys on columns 13-16 still work
  assert_equal(device:get_led(13, 3), 4, "slot 1's clear key")
  -- on page 1 the key is a pattern step again
  tap(context, 1, 5, 8)
  tap(context, 1, 12, 4)
  assert_equal(params:get("v4_freeze"), 1, "page 1's step key leaves freeze alone")
end)

test("128h lights the sounding step between steps, as SEQ does (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 16, 8)
  local function led(voice_idx, step) return device:get_led(step, voice_idx) end
  S.patterns[1][2] = 9
  grid_redraw()
  assert_equal(led(1, 2), 9, "stopped: the stored level")
  assert_equal(led(2, 1), 0, "stopped: no playhead")
  pattern_toggle()  -- step 1 plays at once
  grid_redraw()
  assert_equal(led(2, 1), 4, "just started: step 1 is the playhead")
  assert_equal(led(2, PATTERN_LENGTH), 0, "never the last step")
  h.wake(context, "pattern_clock")  -- step 2 plays; the position is now 3
  grid_redraw()  -- a redraw between steps (a key press)
  assert_equal(S.pattern_position, 3)
  assert_equal(led(1, 2), 15, "the sounding active step at 15")
  assert_equal(led(2, 2), 4, "the sounding empty step at 4")
  assert_equal(led(2, 3), 0, "not the next step")
  assert_equal(S.lib.sequencer.sounding_step(), 2, "the step SEQ draws")
  pattern_toggle()
  assert_equal(led(1, 2), 9, "stopped: the stored level again")
  assert_equal(led(2, 2), 0)
end)

-- Voices 1-3 on slot 1 (16 s), a 128h grid on port 1
local function position_setup()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16; S.buffers[1].loaded = true
  for voice_idx = 1, 3 do params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1) end
  local device = context.grid.plug(1, 16, 8)
  return context, S, device
end

test("128h: the sources key pressed on page 4 shows page 5 and again goes back", function()
  local context, _, device = position_setup()
  tap(context, 1, 8, 8)
  assert_equal(grid_core().page(1), 4, "the sources page")
  assert_equal(device:get_led(8, 8), 15, "shown 15 on page 4")
  tap(context, 1, 8, 8)
  assert_equal(grid_core().page(1), 5, "page 5")
  assert_equal(device:get_led(8, 8), 10, "10 on page 5")
  tap(context, 1, 8, 8)
  assert_equal(grid_core().page(1), 4, "back to page 4")
  assert_equal(device:get_led(8, 8), 15)
  tap(context, 1, 8, 8); tap(context, 1, 6, 8)
  assert_equal(grid_core().page(1), 2, "the other page keys leave page 5 as before")
end)

test("128h: a position press jumps, selects the grid voice and a held pair sets the loop", function()
  local context, S = position_setup()
  tap(context, 1, 8, 8); tap(context, 1, 8, 8)
  assert_equal(grid_core().page(1), 5)
  tap(context, 1, 5, 2)
  assert_near(params:get("v2_buf_pos"), 0.25, 1e-6, "cell 5 of 16")
  assert_equal(S.grid_voice_select, 2, "the grid voice")
  context.grid.press(1, 5, 2, 1)
  context.grid.press(1, 9, 2, 1)
  assert_near(params:get("v2_loop_start"), 0.25, 1e-6, "loop start")
  assert_near(params:get("v2_loop_length"), 0.3125, 1e-6, "loop length")
  context.grid.press(1, 9, 2, 0); context.grid.press(1, 5, 2, 0)
  assert_true(S.lib.positions.grid_level(2, 5, S.constants.GRID_PAGES.position_cells) > 0, "the LEDs come from positions")
end)

test("128h: the grid voice's strip on page 4 recalls, stores, holds and restores the whole loop", function()
  local context, S = position_setup()
  tap(context, 1, 8, 8)
  select_grid_voice(2)
  tap(context, 1, 14, 5)
  assert_near(params:get("v2_buf_pos"), 0.25, 1e-6, "bookmark 2")
  params:set("v2_buf_pos", 0.6)
  context.grid.press(1, 13, 6, 1)
  context.grid.press(1, 15, 5, 1); context.grid.press(1, 15, 5, 0)
  context.grid.press(1, 13, 6, 0)
  assert_near(S.lib.positions.bookmark(2, 3), 0.6, 1e-6, "(13,6) held + (15,5) stores bookmark 3")
  context.clear_engine_calls()
  context.grid.press(1, 14, 6, 1)
  local held
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  assert_equal(held, 1, "scanHold 1")
  context.grid.press(1, 14, 6, 0)
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  assert_equal(held, 0, "scanHold 0: the release reaches the strip")
  params:set("v2_loop_length", 0.5)
  tap(context, 1, 15, 6)
  assert_near(params:get("v2_loop_length"), 1, 1e-6, "whole loop")
  assert_near(params:get("v2_loop_start"), 0, 1e-6)
end)

test("128h: page 4's strip follows a change made off the grid within a tick (#322)", function()
  local context, S, device = position_setup()
  tap(context, 1, 8, 8)
  select_grid_voice(2)
  context.clock.run_for(0.5)
  assert_equal(grid_core().page(1), 4, "page 4")
  assert_equal(device:get_led(15, 6), S.lib.positions.LEVELS.whole, "whole: the loop is the whole slot")
  params:set("v2_loop_length", 0.5)  -- the arc, an LFO or a scene moves the loop
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device:get_led(15, 6), S.lib.positions.LEVELS.key_up, "the strip's whole key repainted")
end)

test("128h: a bookmark changed off the grid repaints page 4's strip at the next tick (#322)", function()
  local context, S, device = position_setup()
  tap(context, 1, 8, 8)
  select_grid_voice(2)
  context.clock.run_for(0.5)
  assert_equal(grid_core().page(1), 4, "page 4")
  local before = device.refresh_count
  params:set("v2_bookmark_3", 0.9)  -- BUFFER's field, an arc ring or a scene fade sets the param
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device.refresh_count, before + 1, "a bookmark stored off the grid: one redraw")
  S.lib.positions.store_bookmark(2, 4)  -- the strip's own store, called as the BUFFER page's would
  params:set("v2_bookmark_4", 0)         -- and cleared
  context.clock.run_for(1 / 15 + 0.01)
  assert_equal(device.refresh_count, before + 2, "a bookmark cleared off the grid: one more")
  context.clock.run_for(1)
  assert_equal(device.refresh_count, before + 2, "and no more")
end)

test("128h: a synth voice's strip is dark and stores nothing (#445)", function()
  local context, S, device = position_setup()
  tap(context, 1, 8, 8)
  params:set("v2_source", 1)
  select_grid_voice(2)
  grid_redraw()
  for n = 1, 4 do assert_equal(device:get_led(12 + n, 5), 0, "bookmark " .. n) end
  for column = 13, 15 do assert_equal(device:get_led(column, 6), 0, "key column " .. column) end
  context.grid.press(1, 13, 6, 1)
  context.grid.press(1, 14, 5, 1)
  assert_equal(device:get_led(13, 6), 0, "store held: dark")
  assert_equal(device:get_led(14, 5), 0, "the pressed bookmark: dark")
  assert_equal(params:get("v2_bookmark_2"), 0.25, "and the bookmark keeps its value")
  context.grid.press(1, 14, 5, 0); context.grid.press(1, 13, 6, 0)
end)

test("128h: pages 1-4 keep every other key", function()
  local context, S, device = position_setup()
  tap(context, 1, 8, 8)
  context.clear_engine_calls()
  for _, key in ipairs({{16, 6}, {13, 7}, {16, 7}, {11, 3}}) do
    tap(context, 1, key[1], key[2])
  end
  assert_equal(#context.calls_named("setGrainParam"), 0, "cells outside the strip send nothing")
  tap(context, 1, 5, 8); tap(context, 1, 8, 8)
  assert_equal(grid_core().page(1), 4, "(8, 8) on page 1 goes to page 4 as before")
  tap(context, 1, 7, 8)
  assert_equal(grid_core().page(1), 3, "page 3 still reached")
  tap(context, 1, 8, 8)
  assert_equal(grid_core().page(1), 4, "(8, 8) on page 3 goes to page 4")
end)

test("128h: the strip's dark cells light and an armed slot's record key lights 11", function()
  local context, S, device = position_setup()
  tap(context, 1, 8, 8)
  select_grid_voice(2)
  grid_redraw()
  for n = 1, 4 do
    assert_equal(device:get_led(12 + n, 5), S.lib.positions.strip_level(2, n), "bookmark " .. n)
  end
  assert_equal(device:get_led(13, 6), S.lib.positions.strip_level(2, "store"))
  assert_equal(device:get_led(14, 6), S.lib.positions.strip_level(2, "hold"))
  assert_equal(device:get_led(15, 6), S.lib.positions.strip_level(2, "whole"))
  assert_equal(device:get_led(16, 6), 0, "column 16 of row 6 stays dark")
  params:set("record_duration", 4); params:set("record_sync", 3)
  tap(context, 1, 13, 1)
  context.polls.fire("recordState", 32)
  assert_equal(S.lib.record.state(1).phase, "armed")
  grid_redraw()
  assert_equal(device:get_led(13, 1), 11, "armed")
end)

local function scan_holds(context)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then table.insert(sent, {voice = call.args[1], value = call.args[3]}) end
  end
  return sent
end

test("128h: a strip key's release goes to the voice it was pressed for", function()
  local context, S = position_setup()
  tap(context, 1, 8, 8)
  select_grid_voice(1)
  context.clear_engine_calls()
  context.grid.press(1, 14, 6, 1)
  tap(context, 1, 16, 8)  -- the next grid voice
  assert_equal(S.grid_voice_select, 2)
  context.grid.press(1, 14, 6, 0)
  local last = {}
  for _, each in ipairs(scan_holds(context)) do last[each.voice] = each.value end
  assert_equal(last[0], 0, "voice 1's hold ended, through positions")
  assert_equal(S.lib.positions.scan_held(1), false)
end)

-- #239: store belongs to the port while its key is down
test("128h: store held, the grid voice changed: a bookmark press stores for the voice shown", function()
  local context, S, device = position_setup()
  local positions = S.lib.positions
  tap(context, 1, 8, 8)
  select_grid_voice(1)
  if S.voices[2].active then toggle_voice(2) end
  assert_true(not S.voices[2].active, "voice 2 stopped")
  params:set("v2_loop_length", 0.5); params:set("v2_loop_start", 0.25); params:set("v2_buf_pos", 0.2)
  local v1_bookmark = params:get("v1_bookmark_1")
  context.grid.press(1, 13, 6, 1)
  tap(context, 1, 16, 8)
  assert_equal(S.grid_voice_select, 2, "(16, 8) cycles to voice 2")
  local position_before = params:get("v2_buf_pos")
  context.grid.press(1, 13, 5, 1)
  assert_near(params:get("v2_bookmark_1"), 0.35, 1e-6, "voice 2's buf_pos mapped into its loop is stored")
  assert_near(params:get("v2_buf_pos"), position_before, 1e-9, "no recall: buf_pos unchanged")
  assert_equal(positions.last_recalled(2), nil, "nothing recalled")
  assert_near(params:get("v1_bookmark_1"), v1_bookmark, 1e-9, "voice 1's bookmark unchanged")
  grid_redraw()
  assert_equal(device:get_led(13, 6), 15, "store lit while held")
  assert_equal(device:get_led(13, 5), 15, "the stored bookmark lit while held")
  context.grid.press(1, 13, 5, 0)
  context.grid.press(1, 13, 6, 0)
  params:set("v2_buf_pos", 0.9)
  tap(context, 1, 13, 5)
  local start, length = params:get("v2_loop_start"), params:get("v2_loop_length")
  assert_near(start + params:get("v2_buf_pos") * length, 0.35, 1e-6, "store up: a press recalls the bookmark")
  assert_equal(positions.last_recalled(2), 1)
end)

test("128h: a bookmark released after a grid voice change goes dark for the voice it stored", function()
  local context, S = position_setup()
  local positions = S.lib.positions
  tap(context, 1, 8, 8)
  select_grid_voice(1)
  context.grid.press(1, 13, 6, 1)
  context.grid.press(1, 13, 5, 1)
  assert_equal(positions.strip_level(1, 1, 1), 15, "bookmark 1 stored for voice 1, its key down")
  tap(context, 1, 16, 8)
  assert_equal(S.grid_voice_select, 2)
  context.grid.press(1, 13, 5, 0)
  assert_true(positions.strip_level(1, 1, 1) ~= 15, "the release ends voice 1's pressed bookmark")
  assert_equal(positions.strip_level(2, "store", 1), 15, "store still down")
  context.grid.press(1, 13, 6, 0)
end)

-- The final review's item 1: the hold key shows the hold whoever changes it,
-- also when no key of this grid changes it
test("128h: the hold key lights for a 256's hold and goes dark when the 256 leaves", function()
  local context, S, device = position_setup()
  local LEVELS = S.lib.positions.LEVELS
  tap(context, 1, 8, 8)  -- page 4
  select_grid_voice(1)
  grid_redraw()
  assert_equal(device:get_led(14, 6), LEVELS.key_up, "not held")
  context.grid.plug(2, 16, 16)
  tap(context, 2, 12, 8)  -- the 256's page 5
  context.grid.press(2, 7, 9, 1)  -- voice 1's hold key, held
  assert_equal(S.lib.positions.scan_held(1), true, "the 256 holds voice 1")
  assert_equal(device:get_led(14, 6), LEVELS.key_down, "the 256's hold lights the 128h's hold key")
  context.grid.unplug(2)
  context.clock.run_for(0.2)
  assert_equal(S.lib.positions.scan_held(1), false, "the tick released the gone grid's hold")
  assert_equal(device:get_led(14, 6), LEVELS.key_up, "and the 128h's hold key goes dark")
end)

test("128h: the hold key lights while BUFFER's ALT ring 1 holds and goes dark when ALT comes up", function()
  local context, S, device = position_setup()
  local LEVELS = S.lib.positions.LEVELS
  tap(context, 1, 8, 8)  -- page 4
  select_grid_voice(1)
  context.arc.plug(1)
  h.show_page("BUFFER")
  assert_equal(S.selected_voice, 1)
  grid_redraw()
  assert_equal(device:get_led(14, 6), LEVELS.key_up, "not held")
  key(1, 1)
  context.arc.turn(1, 1, 1)
  assert_equal(S.lib.positions.scan_held(1), true, "the arc holds voice 1")
  assert_equal(device:get_led(14, 6), LEVELS.key_down, "the arc's hold lights the hold key")
  key(1, 0)
  assert_equal(S.lib.positions.scan_held(1), false, "ALT up releases it")
  assert_equal(device:get_led(14, 6), LEVELS.key_up, "and the hold key goes dark")
end)

-- The final review's item 6 (#256 with #238 and #239): a grid moved in
-- SYSTEM > DEVICES lets go of what its keys held
test("128h: a grid moved to another port releases its store at once and its scan hold at the next tick", function()
  local context, S = position_setup()
  local positions = S.lib.positions
  tap(context, 1, 8, 8)  -- page 4
  select_grid_voice(1)
  context.grid.press(1, 14, 6, 1)  -- hold, held
  context.grid.press(1, 13, 6, 1)  -- store, held
  assert_equal(positions.scan_held(1), true, "the grid holds voice 1's scan")
  assert_equal(positions.strip_level(1, "store"), positions.LEVELS.key_down, "store is down")
  _menu.set_mode(true)  -- SYSTEM > DEVICES
  context.grid.reassign(1, 2)
  _menu.set_mode(false)
  assert_equal(positions.strip_level(1, "store", 2), positions.LEVELS.key_up, "on its new port the store is up at once")
  tap(context, 2, 8, 8)  -- the moved grid starts on page 1: back to page 4
  local bookmark = params:get("v1_bookmark_1")
  params:set("v1_buf_pos", 0.6)
  context.grid.press(2, 13, 5, 1)
  assert_near(params:get("v1_bookmark_1"), bookmark, 1e-9, "a bookmark press there recalls: nothing stored")
  context.grid.press(2, 13, 5, 0)
  context.clock.run_for(0.2)
  assert_equal(positions.scan_held(1), false, "the next playhead tick released the scan hold")
  assert_equal(positions.holds_scan(1, "grid:1"), false, "the old port holds nothing")
  assert_equal(positions.holds_scan(1, "grid:2"), false, "nor the new one")
  assert_equal(positions.strip_level(1, "store"), positions.LEVELS.key_up, "no port holds store")
end)

test("128h: the page 4 cells next to the strip still act", function()
  local context, S = position_setup()
  tap(context, 1, 8, 8)
  tap(context, 1, 3, 4)
  assert_equal(params:get("v4_source"), 3, "a source key")
  context.clear_engine_calls()
  tap(context, 1, 12, 3)
  assert_true(S.lib.freeze.is_frozen(3), "the freeze key")
  tap(context, 1, 13, 3)
  assert_equal(#context.calls_named("clearBuffer"), 1, "a clear key")
  tap(context, 1, 14, 1)
  assert_equal(#context.calls_named("recordBuffer"), 1, "a record key")
end)


-- Every LED of the grid as one string
local function frame(device)
  local levels = {}
  for y = 1, 8 do
    for x = 1, 16 do levels[#levels + 1] = device:get_led(x, y) end
  end
  return table.concat(levels, " ")
end

-- #444: page 4's strip acts on the grid voice; column 11 of its row names it
test("128h page 4 marks the grid voice in column 11, so the cycle key changes an LED (#444)", function()
  local context, S, device = position_setup()
  params:set("v4_source", S.constants.SOURCE_SYNTH + 1)  -- voices 3 and 4 on the same slot
  tap(context, 1, 8, 8)  -- page 4
  select_grid_voice(3); grid_redraw()
  local voice_3 = frame(device)
  for y = 1, 7 do
    assert_equal(device:get_led(11, y), y == 3 and grid_core().LEVELS.picked or 0, "column 11 row " .. y)
  end
  tap(context, 1, 16, 8)  -- the cycle key: voice 4
  assert_equal(S.grid_voice_select, 4, "the cycle key picks voice 4")
  assert_true(frame(device) ~= voice_3, "the frame changed")
  assert_equal(device:get_led(11, 4), grid_core().LEVELS.picked, "column 11 marks row 4")
  assert_equal(device:get_led(11, 3), 0, "and row 3 no longer")
  tap(context, 1, 11, 4)
  assert_equal(S.grid_voice_select, 4, "the marker is not a key")
end)

-- The values a controller got on cc, in order, comma-joined
local function cc_echoes(controller, cc)
  local values = {}
  for _, message in ipairs(controller.sent) do
    if message[2] == cc then table.insert(values, message[3]) end
  end
  return table.concat(values, ",")
end
-- #538: norns' Binary:set sends no MIDI-map CC (only ParamSet:delta does),
-- so the sequencer key sets its binary param through set_binary_param
-- (lib/ui/params.lua), and a controller mapped to it in PARAMS > MAP
-- follows. The map is as lua/core/pmap.lua's pmap.new makes it, echo on
test("128h page 3: the sequencer key echoes to a MIDI-mapped controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 8)
  local controller = context.midi.plug(1)
  norns.pmap.data.scene_sequencer_enabled = { dev = 1, ch = 1, cc = 41, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  tap(context, 1, 7, 8)   -- page 3, scenes
  tap(context, 1, 1, 5)
  assert_equal(params:get("scene_sequencer_enabled"), 1, "(1,5) turns the sequencer on")
  tap(context, 1, 1, 5)
  assert_equal(params:get("scene_sequencer_enabled"), 0, "and off")
  assert_equal(cc_echoes(controller, 41), "127,0", "the controller hears both")
end)

-- The levels of a row, columns 1-16, as one string
local function row_levels(device, y)
  local levels = {}
  for x = 1, 16 do levels[x] = device:get_led(x, y) end
  return table.concat(levels, " ")
end

-- 3.4 (design §11): page 3's columns 9-16 are scenes 9-16 and row 4's
-- columns 9-16 the lengths 9-16
test("128h page 3: scenes 9-16 on columns 9-16, lengths 9-16 on row 4", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  local S = local_value("S")
  local core = grid_core()
  tap(context, 1, 7, 8)  -- page 3
  context.grid.press(1, 11, 3, 1)
  context.clock.run_for(0.51)
  context.grid.press(1, 11, 3, 0)
  assert_true(S.scenes[11].populated, "(11,3) held 0.5 s saves scene 11")
  capture_scene(16); grid_redraw()
  for i = 9, 16 do
    assert_equal(device:get_led(i, 1), core.scene_recall_level(i), "recall key " .. i)
    assert_equal(device:get_led(i, 2), core.scene_fade_level(i), "fade key " .. i)
    assert_equal(device:get_led(i, 3), core.scene_save_level(1, i, 3), "save key " .. i)
  end
  assert_equal(device:get_led(11, 2), 6, "populated scene 11's fade key at 6")
  local scheduled = {}
  local real_schedule = S.lib.quantize.schedule
  S.lib.quantize.schedule = function(action_key, fn, label)
    table.insert(scheduled, action_key .. " " .. label); fn(); return true
  end
  tap(context, 1, 16, 1)
  assert_equal(S.current_scene, 16, "(16,1) recalls scene 16 at once")
  params:set("scene_transition_time", 2)
  tap(context, 1, 11, 2)
  assert_true(S.scene_transition_active and S.SCENE_TRANSITION.target == 11, "(11,2) fades to scene 11")
  S.lib.quantize.schedule = real_schedule
  assert_equal(table.concat(scheduled, ","), "scene S16,scene S11", "both recalls go through the quantizer")
  context.clock.run_for(2.5)
  tap(context, 1, 16, 4); assert_equal(params:get("scene_sequence_length"), 16, "(16,4) length 16")
  tap(context, 1, 9, 4); assert_equal(params:get("scene_sequence_length"), 9, "(9,4) length 9")
  tap(context, 1, 8, 4); assert_equal(params:get("scene_sequence_length"), 8, "(8,4) still length 8")
  tap(context, 1, 13, 4)
  assert_equal(row_levels(device, 4), "8 8 8 8 8 8 8 8 8 8 8 8 8 2 2 2", "row 4: lengths 1-13 within it")
end)

-- 3.4 (design §4.6, §11): page 2's row 5 column 16 steps the faders voice
-- faders -> bank 1 -> 2 -> 3 -> 4 -> voice faders (LED 4, 6, 9, 12, 15),
-- setting the shown bank; rows 1-4 are then the bank's four macros
test("the macro page key cycles voice faders and the four banks, with its LED", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  local S = local_value("S")
  local ids = fader_param_ids(1)
  tap(context, 1, 6, 8)  -- page 2
  assert_equal(device:get_led(16, 5), 4, "voice faders: 4")
  S.lib.macros.set_bank(3)
  tap(context, 1, 16, 5)
  assert_equal(S.lib.macros.bank(), 1, "from the voice faders: bank 1")
  assert_equal(device:get_led(16, 5), 6, "bank 1: 6")
  tap(context, 1, 16, 1)
  assert_near(params:get("macro_1"), 1.0, 1e-9, "row 1 is macro_1")
  assert_equal(row_levels(device, 1), "8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 15", "as a fader row")
  local expected = {9, 12, 15}
  for bank = 2, 4 do
    tap(context, 1, 16, 5)
    assert_equal(S.lib.macros.bank(), bank, "the next press: bank " .. bank)
    assert_equal(device:get_led(16, 5), expected[bank - 1], "bank " .. bank .. "'s level")
  end
  tap(context, 1, 1, 4)
  assert_near(params:get("macro_16"), 0, 1e-9, "bank 4: row 4 is macro_16")
  tap(context, 1, 16, 2)
  assert_near(params:get("macro_14"), 1.0, 1e-9, "and row 2 macro_14")
  S.lib.macros.set_bank(2)
  assert_equal(device:get_led(16, 5), 9, "a bank shown from elsewhere: its level")
  tap(context, 1, 8, 1)
  assert_near(params:get("macro_5"), 7 / 15, 1e-9, "and its macros")
  tap(context, 1, 16, 5); tap(context, 1, 16, 5); tap(context, 1, 16, 5)
  assert_equal(device:get_led(16, 5), 4, "after bank 4: the voice faders again")
  assert_equal(S.lib.macros.bank(), 4, "which keep the bank")
  tap(context, 1, 16, 1)
  assert_equal(fader_position(ids[1]), 16, "row 1 is the voice's fader 1 again")
  -- the view is per grid, and a macro set off the grid shows within a tick
  local other = context.grid.plug(2, 16, 8)
  tap(context, 2, 6, 8); tap(context, 2, 16, 5)
  assert_equal(other:get_led(16, 5), 6, "grid 2 shows bank 1")
  assert_equal(device:get_led(16, 5), 4, "grid 1 still the voice faders")
  params:set("macro_2", 1)
  drift_update()
  assert_equal(other:get_led(16, 2), 15, "macro_2 set elsewhere: grid 2's row 2 follows")
end)

-- 3.4 (design §11): page 3's row 5 columns 13-16 are the gesture recorders
-- (a press; a 0.5 s hold clears) and row 6 the morph fader
test("the morph fader and the recorder keys", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  local S = local_value("S")
  tap(context, 1, 7, 8)  -- page 3
  assert_equal(row_levels(device, 5):sub(-7), "2 2 2 2", "four empty recorders at 2")
  tap(context, 1, 16, 6)
  assert_near(params:get("morph"), 1.0, 1e-9, "(16,6) moves the morph to 1")
  assert_equal(row_levels(device, 6), "8 8 8 8 8 8 8 8 8 8 8 8 8 8 8 15", "drawn as a fader")
  tap(context, 1, 14, 5)
  assert_equal(S.lib.gestures.state(2), "recording", "(14,5) presses recorder 2")
  assert_equal(device:get_led(14, 5), 15, "recording: 15")
  tap(context, 1, 4, 6)
  tap(context, 1, 14, 5)
  assert_equal(S.lib.gestures.state(2), "playing", "the morph's move recorded and playing")
  assert_equal(device:get_led(14, 5), 10)
  context.grid.press(1, 14, 5, 1); context.clock.run_for(0.51); context.grid.press(1, 14, 5, 0)
  assert_equal(S.lib.gestures.state(2), "empty", "held 0.5 s: cleared")
  params:set("morph", 0.5)
  drift_update()
  assert_equal(device:get_led(9, 6), 15, "the morph set elsewhere shows within a tick")
  assert_equal(device:get_led(1, 5), 4, "row 5 column 1 is still the sequencer key")
end)

-- (mute) design §8.14: a silenced running voice's key lights at 6
test("a silenced voice's key lights at 6 on every layout", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 8)
  toggle_voice(3)
  assert_equal(device:get_led(11, 8), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(11, 8), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0); params:set("v4_solo", 1)
  assert_equal(device:get_led(11, 8), 6, "silenced by voice 4's solo: 6")
  assert_equal(device:get_led(12, 8), 2, "voice 4, soloed but stopped: 2")
end)

-- design §8.9 and §8.7: the freeze keys go through toggle_quantized, and
-- the step keys toggle on release
test("128h: a freeze key waits for the beat and a step key toggles on release", function()
  local context = load_strata(); finish_startup(context)
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8)
  context.grid.press(1, 9, 2, 1)
  assert_equal(patterns[2][9], 0, "the press leaves voice 2's step 9")
  context.grid.press(1, 9, 2, 0)
  assert_equal(patterns[2][9], 15, "the release toggles it")
  params:set("quantize_actions", 2)  -- beat
  context.clock.run_for(0.25)
  tap(context, 1, 8, 8)  -- page 4
  tap(context, 1, 12, 3)
  assert_equal(params:get("v3_freeze"), 0, "the freeze key waits for the beat")
  context.clock.run_for(0.3)
  assert_equal(params:get("v3_freeze"), 1, "and freezes voice 3 at it")
end)

-- Fix round 2: a release acts only for the key pressed in its role: a step
-- key held into page 3 and let go on recorder 1's cell records nothing
test("128h: a step key held into page 3 is no recorder key at its release", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 8)
  context.grid.press(1, 13, 5, 1)  -- page 1: voice 5's step 13
  tap(context, 1, 7, 8)            -- page 3
  context.grid.press(1, 13, 5, 0)  -- let go on recorder 1's cell
  assert_equal(S.lib.gestures.state(1), "empty", "recorder 1 records nothing")
  assert_equal(patterns[5][13], 0, "and the step is untouched")
  tap(context, 1, 13, 5)
  assert_equal(S.lib.gestures.state(1), "recording", "the recorder key's own tap records")
  S.lib.gestures.clear(1)
end)

end

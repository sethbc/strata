-- test/unit/grid_layout_128v_test.lua
-- The 8x16 grid layout (lib/grid/layout_128v.lua): pages 1-5 (patterns,
-- faders, scenes, sources, positions) cycled by (8,8)
-- Run alone: lua test/run.lua grid_layout_128v

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function grid_core() return local_value("S").lib.grid_core end
local function tap(context, port, x, y)
  context.grid.press(port, x, y, 1); context.grid.press(port, x, y, 0)
end
-- (8,8) until the port shows the page
local function show_grid_page(context, port, page)
  for _ = 1, 5 do
    if grid_core().page(port) == page then return end
    tap(context, port, 8, 8)
  end
  assert_equal(grid_core().page(port), page, "reached grid page " .. page)
end

test("every 128v grid key runs without error", function()
  local context = load_strata()
  local device = context.grid.plug(1, 8, 16)
  for page = 1, 5 do
    show_grid_page(context, 1, page)
    for y = 1, 16 do
      for x = 1, 8 do
        if not (x == 8 and y == 8) then
          context.grid.press(1, x, y, 1)
          context.grid.press(1, x, y, 0)
          context.clock.advance()
        end
      end
    end
    assert_equal(grid_core().page(1), page, "only (8,8) changes the page")
  end
  assert_true(device.refresh_count > 0, "128v grid was redrawn")
end)

test("128v: the faders page's column 7 locks and unlocks voices 1-7", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local frozen = local_value("S").frozen
  show_grid_page(context, 1, 2)
  -- column 7 rows 10-16: voices 1-7, lit 12 locked and 2 not
  tap(context, 1, 7, 12)
  assert_true(frozen[3], "column 7 row 12 locks voice 3")
  assert_equal(device:get_led(7, 12), 12, "a locked voice's key is lit 12")
  assert_equal(device:get_led(7, 10), 2, "an unlocked voice's key is lit 2")
  tap(context, 1, 7, 12)
  assert_true(not frozen[3], "a second press unlocks")
  assert_equal(device:get_led(7, 12), 2, "unlocked again, lit 2")
  -- rows 1-9 of column 7 stay dark and do nothing
  for y = 1, 9 do
    tap(context, 1, 7, y)
    assert_equal(device:get_led(7, y), 0, "column 7 row " .. y .. " stays dark")
  end
  for i = 1, 7 do assert_true(not frozen[i], "rows 1-9 lock no voice") end
  -- column 6 is inert: no lock, no fader param and no fader page changes
  local fader_ids = fader_param_ids(local_value("grid_voice_select"))
  local values_before, page_before = {}, local_value("param_page")
  for i, id in ipairs(fader_ids) do values_before[i] = params:get(id) end
  for _, y in ipairs({3, 12}) do
    tap(context, 1, 6, y)
    assert_equal(device:get_led(6, y), 0, "column 6 row " .. y .. " stays dark")
  end
  for i = 1, 7 do assert_true(not frozen[i], "column 6 locks no voice") end
  for i, id in ipairs(fader_ids) do
    assert_equal(params:get(id), values_before[i], "column 6 changed no fader param: " .. id)
  end
  assert_equal(local_value("param_page"), page_before, "column 6 changed no fader page")
  -- on page 1 a press at (7, 12) is voice 7's step 12, as before
  show_grid_page(context, 1, 1)
  local step_before = local_value("S").patterns[7][12]
  tap(context, 1, 7, 12)
  assert_true(local_value("S").patterns[7][12] ~= step_before, "page 1 (7, 12) toggles step 12")
  assert_true(not frozen[3], "page 1 locks nothing")
end)

test("grid_redraw draws the 128v layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 8, 16)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "128v redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 8 do
    for y = 1, 16 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "128v layout drew something")
end)

test("128v (8,8) cycles five pages and shows the page in its LED", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local levels = {3, 6, 9, 12, 15}
  assert_equal(grid_core().page(1), 1, "a grid starts on the patterns page")
  for _, page in ipairs({1, 2, 3, 4, 5, 1}) do
    assert_equal(grid_core().page(1), page)
    assert_equal(device:get_led(8, 8), levels[page], "page " .. page .. " LED level")
    tap(context, 1, 8, 8)
  end
  -- pages are per grid
  local other = context.grid.plug(2, 8, 16)
  assert_equal(grid_core().page(2), 1, "a second grid keeps its own page")
  assert_equal(other:get_led(8, 8), 3)
  assert_equal(grid_core().page(1), 2)
end)

test("128v column 8: voices and play on every page, voice select on pages 1-3", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local voices = local_value("voices")
  for page = 1, 4 do
    show_grid_page(context, 1, page)
    local was_active = voices[5].active
    tap(context, 1, 8, 5)
    assert_true(voices[5].active ~= was_active, "page " .. page .. ": (8,5) toggles voice 5")
    assert_equal(device:get_led(8, 5), voices[5].active and 12 or 2, "the shared voice levels (#526)")
    local playing = local_value("pattern_playing")
    tap(context, 1, 8, 9)
    assert_true(local_value("pattern_playing") ~= playing, "page " .. page .. ": (8,9) plays or stops")
    assert_equal(device:get_led(8, 9), local_value("pattern_playing") and 15 or 4)
    if local_value("pattern_playing") then pattern_toggle() end
    if page <= 3 then
      tap(context, 1, 8, 10 + page)
      assert_equal(local_value("grid_voice_select"), 1 + page, "page " .. page .. ": rows 10-16 select")
      assert_equal(device:get_led(8, 10 + page), 15, "the selected voice is lit")
      assert_equal(device:get_led(8, 10), 4, "the others dim (the shared pick levels, #526)")
    end
  end
  -- on the sources page column 8 rows 10-16 select no voice
  show_grid_page(context, 1, 4)
  local selected = local_value("grid_voice_select")
  for _, y in ipairs({10, 11, 14, 15, 16}) do
    tap(context, 1, 8, y)
    assert_equal(device:get_led(8, y), 0, "row " .. y .. " is dark on the sources page")
  end
  assert_equal(local_value("grid_voice_select"), selected, "no voice select on the sources page")
end)

test("128v patterns page: steps down each voice's column", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local patterns = local_value("patterns")
  tap(context, 1, 3, 12)
  assert_equal(patterns[3][12], 15, "(3,12) toggles voice 3 step 12")
  assert_equal(device:get_led(3, 12), 15)
  context.grid.press(1, 3, 12, 1); context.grid.press(1, 3, 4, 1)
  assert_equal(patterns[3][12], 4, "with step 12 held, row 4 of 16 sets its level to 4")
  assert_equal(patterns[3][4], 0, "the level key does not toggle")
  context.grid.press(1, 3, 4, 0); context.grid.press(1, 3, 12, 0)
  -- other pages do not edit patterns
  show_grid_page(context, 1, 2)
  tap(context, 1, 6, 6)
  show_grid_page(context, 1, 3)
  tap(context, 1, 6, 6)
  show_grid_page(context, 1, 4)
  tap(context, 1, 6, 14)
  assert_equal(patterns[6][6] + patterns[6][14], 0, "columns 1-7 edit steps on the patterns page only")
end)

test("128v sources page", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local buffers = local_value("buffers")
  show_grid_page(context, 1, 4)
  tap(context, 1, 2, 5)
  assert_equal(params:get("v2_source"), 5, "(2,5) -> buffer 4")
  assert_equal(device:get_led(2, 5), 15, "the selected source at 15")
  tap(context, 1, 2, 10)
  assert_equal(params:get("v2_source"), 10, "(2,10) -> input")
  tap(context, 1, 2, 1)
  assert_equal(params:get("v2_source"), 1, "(2,1) -> synth")
  for x = 1, 7 do
    for y = 1, 10 do
      assert_equal(device:get_led(x, y), grid_core().source_level(x, y), "source LED " .. x .. "," .. y)
    end
    assert_equal(device:get_led(x, 11), 0, "row 11 is dark")
  end
  -- row 12 records, row 13 clears; column 8 is slot 8
  tap(context, 1, 3, 12)
  assert_equal(context.calls_named("recordBuffer")[1].args[1], 2, "(3,12) records slot 3")
  assert_true(buffers[3].recording)
  assert_equal(device:get_led(3, 12), 15, "a recording slot at 15")
  assert_equal(device:get_led(4, 12), grid_core().record_level(4))
  tap(context, 1, 8, 12)
  assert_equal(context.calls_named("recordBuffer")[2].args[1], 7, "(8,12) records slot 8")
  assert_equal(device:get_led(8, 12), 15)
  tap(context, 1, 8, 13)
  assert_equal(context.calls_named("clearBuffer")[1].args[1], 7, "(8,13) clears slot 8")
  assert_true(not buffers[8].recording, "the clear ends slot 8's recording")
  for x = 1, 8 do
    assert_equal(device:get_led(x, 13), grid_core().CLEAR_LEVEL, "clear key " .. x)
  end
  assert_equal(device:get_led(8, 12), 2, "slot 8 empty again")
end)

test("128v faders page: vertical faders, page selector, voice select", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  show_grid_page(context, 1, 2)
  tap(context, 1, 8, 11)  -- voice 2 (fm)
  assert_equal(local_value("grid_voice_select"), 2)
  local ids = fader_param_ids(2)
  tap(context, 1, 1, 16)
  local freq_min, freq_max = param_range(ids[1])
  assert_near(params:get(ids[1]), freq_min, 1e-6, "(1,16) sets fader 1 to its minimum")
  assert_equal(device:get_led(1, 16), 15, "the value's row at 15")
  assert_equal(device:get_led(1, 15), 0, "nothing above it")
  tap(context, 1, 1, 1)
  assert_near(params:get(ids[1]), freq_max, 1e-6, "(1,1) sets fader 1 to its maximum")
  assert_equal(device:get_led(1, 1), 15)
  assert_equal(device:get_led(1, 16), 8, "the bar below the value")
  -- row y sets what column 17 - y sets on the 256
  set_param_from_column(ids[3], 8)
  local expected = params:get(ids[3])
  set_param_from_column(ids[3], 1)
  tap(context, 1, 3, 9)  -- fader 3, the 256's column 8
  assert_near(params:get(ids[3]), expected, 1e-9, "row 9 sets the 256's column 8 value")
  assert_equal(device:get_led(3, 9), 15)
  assert_equal(device:get_led(3, 10), 8)
  assert_equal(device:get_led(3, 8), 0)
  -- column 5: the fader page selector
  assert_equal(device:get_led(5, 1), 15, "fader page 1 selected")
  assert_equal(device:get_led(5, fader_page_count(2)), 4, "the last fader page available")
  assert_equal(device:get_led(5, fader_page_count(2) + 1), 0, "no page past the last")
  tap(context, 1, 5, 2)
  assert_equal(local_value("param_page"), 2, "(5,2) fader page 2")
  assert_equal(device:get_led(5, 2), 15)
  tap(context, 1, 5, fader_page_count(2) + 1)
  assert_equal(local_value("param_page"), 2, "a page past the last does nothing")
  tap(context, 1, 4, 16)
  local fader_8_min = param_range(ids[8])
  assert_near(params:get(ids[8]), fader_8_min, 1e-6, "page 2's fader 4 is fader 8")
  -- column 6 and column 7 rows 1-9 are dark (column 7 rows 10-16 are the lock keys)
  for y = 1, 16 do
    local column_7 = y <= 9 and device:get_led(7, y) or 0
    assert_equal(device:get_led(6, y) + column_7, 0, "dark keys, row " .. y)
  end
  -- column 8 rows 10-16 select the voice
  tap(context, 1, 8, 12)
  assert_equal(local_value("grid_voice_select"), 3, "(8,12) selects voice 3")
  local folder_ids = fader_param_ids(3)
  local param_page = local_value("param_page")
  local shown = folder_ids[(param_page - 1) * 4 + 1]
  assert_equal(device:get_led(1, 17 - fader_position(shown)), 15, "the faders show voice 3")
end)

test("128v scenes page", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local scenes = local_value("scenes")
  capture_scene(3)
  show_grid_page(context, 1, 3)
  assert_equal(device:get_led(1, 3), 8, "a populated scene at 8")
  assert_equal(device:get_led(1, 4), 2, "an empty one at 2")
  assert_equal(device:get_led(2, 3), 6)
  assert_equal(device:get_led(2, 4), 2)
  tap(context, 1, 1, 3)
  assert_equal(local_value("current_scene"), 3, "(1,3) recalls S3 instantly")
  assert_true(not local_value("scene_transition_active"), "no transition")
  assert_equal(device:get_led(1, 3), 15, "the current scene at 15")
  params:set("scene_transition_time", 2)
  tap(context, 1, 2, 3)
  assert_true(local_value("scene_transition_active"), "(2,3) recalls S3 with a transition")
  context.clock.run_for(2.5)
  -- (3,y) saves on a hold
  assert_equal(device:get_led(3, 5), 4, "save key idle")
  context.grid.press(1, 3, 5, 1)
  assert_equal(device:get_led(3, 5), 15, "a pending save at 15")
  context.clock.run_for(0.3)
  context.grid.press(1, 3, 5, 0)
  assert_true(not scenes[5].populated, "released early: nothing saved")
  context.grid.press(1, 3, 5, 1)
  context.clock.run_for(0.51)
  assert_true(scenes[5].populated, "(3,5) held 0.5 s saves S5")
  context.grid.press(1, 3, 5, 0)
  -- column 4: the sequencer and its length
  assert_equal(device:get_led(4, 1), 4, "sequencer off")
  tap(context, 1, 4, 1)
  assert_equal(params:get("scene_sequencer_enabled"), 1, "(4,1) turns the sequencer on")
  assert_equal(device:get_led(4, 1), 15)
  tap(context, 1, 4, 1)
  assert_equal(params:get("scene_sequencer_enabled"), 0, "and off")
  for length = 1, 8 do
    tap(context, 1, 4, 8 + length)
    assert_equal(params:get("scene_sequence_length"), length, "(4," .. (8 + length) .. ") length " .. length)
  end
  tap(context, 1, 4, 11)
  for length = 1, 8 do
    assert_equal(device:get_led(4, 8 + length), length <= 3 and 8 or 2, "length LED " .. length)
  end
end)

-- #452: the scene keys show the core's levels (grid_core_test.lua holds
-- the rule: the next slot, the current scene, the blink)
test("128v scenes page: the scene keys show the core's levels (#452)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local core = local_value("S").lib.grid_core
  show_grid_page(context, 1, 3)
  capture_scene(1); capture_scene(2); capture_scene(3)
  params:set("scene_sequence_length", 4)
  params:set("scene_transition_time", 0); params:set("scene_duration", 4)
  params:set("scene_sequencer_enabled", 1)
  context.clock.run_for(1, 0.001)  -- scene 1 playing, scene 2 next
  context.grid.press(1, 3, 5, 1)
  local seen = {}
  for i = 1, 8 do
    assert_equal(device:get_led(1, i), core.scene_recall_level(i), "recall key " .. i)
    assert_equal(device:get_led(2, i), core.scene_fade_level(i), "fade key " .. i)
    assert_equal(device:get_led(3, i), core.scene_save_level(1, 3, i), "save key " .. i)
    seen[device:get_led(1, i)] = true
  end
  assert_true(seen[15] and seen[10] and seen[8] and seen[2], "the recall keys show all four levels")
  assert_equal(core.scene_save_level(1, 3, 5), 15, "scene 5's save is pending")
  context.grid.press(1, 3, 5, 0)
  params:set("scene_sequencer_enabled", 0)
end)

test("128v removing the grid mid-save saves nothing", function()
  local context = load_strata(); finish_startup(context)
  local scenes = local_value("scenes")
  context.grid.plug(1, 8, 16)
  show_grid_page(context, 1, 3)
  context.grid.press(1, 3, 6, 1)
  context.grid.unplug(1)
  context.clock.run_for(1)
  assert_true(not scenes[6].populated, "no save after the grid is removed")
  context.grid.plug(1, 8, 16)
  assert_equal(grid_core().page(1), 1, "a grid plugged back starts on page 1")
end)

test("128v row 14 toggles freeze", function()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  local device = context.grid.plug(1, 8, 16)
  for _ = 1, 3 do tap(context, 1, 8, 8) end  -- page 4, the sources page
  assert_equal(grid_core().page(1), 4)
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(device:get_led(voice_idx, 14), 3, "voice " .. voice_idx .. " not frozen: 3")
    tap(context, 1, voice_idx, 14)
    assert_equal(params:get("v" .. voice_idx .. "_freeze"), 1, "row 14 column " .. voice_idx .. " freezes it")
    assert_equal(device:get_led(voice_idx, 14), 15, "frozen: 15")
  end
  tap(context, 1, 5, 14)
  assert_equal(params:get("v5_freeze"), 0, "a second press unfreezes")
  assert_equal(device:get_led(5, 14), 3)
  assert_equal(device:get_led(8, 14), 0, "column 8 row 14 has no freeze key")
  -- the patterns page shows steps there
  tap(context, 1, 8, 8); tap(context, 1, 8, 8)  -- page 5, then 1
  assert_equal(grid_core().page(1), 1)
end)

test("128v lights the sounding step between steps, as SEQ does (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 8, 16)
  local function led(voice_idx, step) return device:get_led(voice_idx, step) end
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

-- Voices 1-3 on slot 1 (16 s), as positions_test does
local function buffer_voices(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  for voice_idx = 1, 3 do params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1) end
  context.clear_engine_calls()
  return S
end

test("128v: columns 1-7 are the voices' positions, row 1 the slot's start", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  show_grid_page(context, 1, 5)
  S.grid_voice_select = 3
  tap(context, 1, 1, 5)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "(1,5) jumps voice 1 to cell 5 of 16")
  assert_equal(S.grid_voice_select, 1, "the press selects the grid voice")
  tap(context, 1, 2, 1)
  assert_near(params:get("v2_buf_pos"), 0, 1e-9, "row 1 is the slot's start")
  context.grid.press(1, 1, 5, 1)
  context.grid.press(1, 1, 9, 1)
  assert_near(params:get("v1_loop_start"), 0.25, 1e-9)
  assert_near(params:get("v1_loop_length"), 0.3125, 1e-9)
  context.grid.press(1, 1, 9, 0); context.grid.press(1, 1, 5, 0)
  for voice_idx = 1, 7 do
    -- the grid voice (1, from the press) one level up (#444)
    local floor = voice_idx == S.grid_voice_select and 1 or 0
    for cell = 1, 16 do
      assert_equal(device:get_led(voice_idx, cell), math.min(15, S.lib.positions.grid_level(voice_idx, cell, 16) + floor),
        "LED " .. voice_idx .. "," .. cell)
    end
  end
end)

test("128v: a synth voice's strip is dark and stores nothing (#445)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  show_grid_page(context, 1, 5)
  S.grid_voice_select = 1
  params:set("v1_source", 1)
  grid_redraw()
  for row = 10, 16 do assert_equal(device:get_led(8, row), 0, "strip row " .. row) end
  context.grid.press(1, 8, 14, 1)
  context.grid.press(1, 8, 12, 1)
  assert_equal(device:get_led(8, 14), 0, "store held: dark")
  assert_equal(device:get_led(8, 12), 0, "the pressed bookmark: dark")
  assert_equal(params:get("v1_bookmark_2"), 0.25, "and the bookmark keeps its value")
  context.grid.press(1, 8, 12, 0); context.grid.press(1, 8, 14, 0)
end)

test("128v: column 8 rows 10-16 are the grid voice's strip", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  local positions = S.lib.positions
  show_grid_page(context, 1, 5)
  S.grid_voice_select = 1
  tap(context, 1, 8, 11)
  assert_equal(positions.last_recalled(1), 2, "(8,11) recalls bookmark 2")
  params:set("v1_buf_pos", 0.6)
  context.grid.press(1, 8, 14, 1)
  tap(context, 1, 8, 12)
  context.grid.press(1, 8, 14, 0)
  assert_near(positions.bookmark(1, 3), 0.6, 1e-6, "(8,14) held + (8,12) stores bookmark 3")
  context.clear_engine_calls()
  context.grid.press(1, 8, 15, 1)
  local held
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  assert_equal(held, 1, "(8,15) held holds the scan")
  assert_equal(device:get_led(8, 15), positions.strip_level(1, "hold"))
  context.grid.press(1, 8, 15, 0)
  held = nil
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  assert_equal(held, 0, "released: 0")
  params:set("v1_loop_start", 0.25); params:set("v1_loop_length", 0.5)
  tap(context, 1, 8, 16)
  assert_equal(params:get("v1_loop_start"), 0, "(8,16) loop back to whole")
  for row = 10, 16 do
    local key = S.lib.grid_layout_128v.LAYOUT.strip_keys[row - 9]
    assert_equal(device:get_led(8, row), positions.strip_level(1, key), "strip LED row " .. row)
  end
end)

-- #239: store belongs to the port while its key is down
test("128v: store held, the grid voice changed: a bookmark press stores for the voice shown", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  local positions = S.lib.positions
  show_grid_page(context, 1, 5)
  S.grid_voice_select = 1
  if S.voices[2].active then toggle_voice(2) end
  assert_true(not S.voices[2].active, "voice 2 stopped")
  local v1_bookmark = params:get("v1_bookmark_1")
  context.grid.press(1, 8, 14, 1)
  tap(context, 1, 2, 5)
  assert_equal(S.grid_voice_select, 2, "a position press in voice 2's column selects it")
  local position_before = params:get("v2_buf_pos")
  assert_near(position_before, 0.25, 1e-9, "the press jumped to cell 5")
  context.grid.press(1, 8, 10, 1)
  assert_near(params:get("v2_bookmark_1"), 0.25, 1e-6, "voice 2's buf_pos is stored")
  assert_near(params:get("v2_buf_pos"), position_before, 1e-9, "no recall: buf_pos unchanged")
  assert_equal(positions.last_recalled(2), nil, "nothing recalled")
  assert_near(params:get("v1_bookmark_1"), v1_bookmark, 1e-9, "voice 1's bookmark unchanged")
  grid_redraw()
  assert_equal(device:get_led(8, 14), 15, "store lit while held")
  assert_equal(device:get_led(8, 10), 15, "the stored bookmark lit while held")
  context.grid.press(1, 8, 10, 0)
  context.grid.press(1, 8, 14, 0)
  params:set("v2_buf_pos", 0.7)
  tap(context, 1, 8, 10)
  assert_near(params:get("v2_buf_pos"), 0.25, 1e-6, "store up: a press recalls the bookmark")
  assert_equal(positions.last_recalled(2), 1)
end)

test("128v: pages 1-4 keep every key and never reach positions", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  local calls = 0
  for _, name in ipairs({"grid_key", "strip_key"}) do
    local original = S.lib.positions[name]
    S.lib.positions[name] = function(...) calls = calls + 1; return original(...) end
  end
  for page = 1, 4 do
    show_grid_page(context, 1, page)
    for y = 1, 16 do
      for x = 1, 8 do
        if not (x == 8 and y == 8) then tap(context, 1, x, y) end
      end
    end
  end
  assert_equal(calls, 0, "pages 1-4 never call S.lib.positions")
end)

test("128v: an armed slot's record key lights 11", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  params:set("record_sync", 3)
  show_grid_page(context, 1, 4)
  tap(context, 1, 1, 12)
  context.polls.fire("recordState", 32)
  grid_redraw()
  assert_equal(device:get_led(1, 12), 11, "an armed slot's record key")
end)

test("128v positions page: releases on column 8 rows 1-9 do nothing, synth voices are ignored", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  show_grid_page(context, 1, 5)
  local was_active = S.voices[3].active
  tap(context, 1, 8, 3)
  assert_true(S.voices[3].active ~= was_active, "a press and release toggles voice 3 once")
  local playing = local_value("pattern_playing")
  tap(context, 1, 8, 9)
  assert_true(local_value("pattern_playing") ~= playing, "(8,9) toggles play once")
  local page = grid_core().page(1)
  context.grid.press(1, 8, 8, 0)
  assert_equal(grid_core().page(1), page, "a page key release does nothing")
  context.clear_engine_calls()
  tap(context, 1, 5, 5)
  assert_equal(#context.calls_named("setGrainParam"), 0, "a synth voice's cell sends no grain param")
  assert_equal(S.grid_voice_select, 1, "and does not select it")
  show_grid_page(context, 1, 2)
  was_active = S.voices[3].active
  context.grid.press(1, 8, 3, 0)
  assert_equal(S.voices[3].active, was_active, "a release on pages 1-4 is ignored")
end)

test("128v: releasing hold after the grid voice changed still ends the first voice's hold", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  show_grid_page(context, 1, 5)
  S.grid_voice_select = 1
  local function last_hold(engine_voice)
    local value
    for _, call in ipairs(context.calls_named("setGrainParam")) do
      if call.args[1] == engine_voice and call.args[2] == "scanHold" then value = call.args[3] end
    end
    return value
  end
  context.grid.press(1, 8, 15, 1)
  assert_equal(last_hold(0), 1, "voice 1 holds the scan")
  S.grid_voice_select = 2
  context.grid.press(1, 8, 15, 0)
  assert_equal(last_hold(0), 0, "released: voice 1's hold ends")
end)


-- Every LED of the grid as one string
local function frame(device)
  local levels = {}
  for y = 1, 16 do
    for x = 1, 8 do levels[#levels + 1] = device:get_led(x, y) end
  end
  return table.concat(levels, " ")
end

-- #444: the strip in column 8 acts on the grid voice; its column of
-- positions lights one level up (a floor of 1 for an empty cell)
test("128v positions page lights the grid voice's column one level up (#444)", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 8, 16)
  local S = buffer_voices(context)
  params:set("v4_source", S.constants.SOURCE_SYNTH + 1)  -- voices 3 and 4 on the same slot
  show_grid_page(context, 1, 5)
  select_grid_voice(3); grid_redraw()
  local voice_3 = frame(device)
  local positions = S.lib.positions
  for cell = 1, 16 do
    assert_equal(device:get_led(3, cell), math.min(15, positions.grid_level(3, cell, 16) + 1), "voice 3 cell " .. cell)
    assert_equal(device:get_led(4, cell), positions.grid_level(4, cell, 16), "voice 4 cell " .. cell)
    assert_equal(device:get_led(5, cell), 0, "voice 5 reads no buffer and is not the grid voice: dark")
  end
  select_grid_voice(4); grid_redraw()
  assert_true(frame(device) ~= voice_3, "the frame for voice 4 differs")
  select_grid_voice(5); grid_redraw()
  for cell = 1, 16 do assert_equal(device:get_led(5, cell), 1, "a grid voice with no buffer lights its floor") end
end)

end

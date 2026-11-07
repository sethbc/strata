-- test/unit/pages_setup_test.lua
-- The SETUP page (lib/pages/setup.lua): its status lines and keys
-- Run alone: lua test/run.lua pages_setup

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap = h.tap

test("SETUP page shows grids, arc and scenes; K3 saves scenes to disk", function()
  local context = load_strata()
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page("SETUP")
  assert_true(screen_has("grid: 0 connected"), "no grids")
  assert_true(screen_has("arc: none"), "no arc")
  assert_true(screen_has("scenes: 0/8 saved"), "no scenes")
  context.grid.plug(1, 16, 16)
  context.grid.plug(3, 8, 8)
  context.arc.plug(1)
  capture_scene(3)
  redraw()
  assert_true(screen_has("grid: 2 connected"), "two grids")
  assert_true(screen_has("16x16 8x8"), "grid sizes in port order")
  assert_true(screen_has("arc: connected"), "arc connected")
  assert_true(screen_has("scenes: 1/8 saved"), "one scene")
  context.arc.unplug(1)
  context.grid.unplug(3)
  next_frame(context)
  assert_true(screen_has("arc: none"), "unplugging the arc redraws SETUP on the next frame")
  assert_true(screen_has("grid: 1 connected"), "unplugging a grid redraws SETUP on the next frame")

  local scene_file = context.data_dir .. "strata/scenes.data"
  assert_true(not util.file_exists(scene_file), "no scenes file yet")
  key(3, 1)
  assert_true(util.file_exists(scene_file), "K3 on SETUP saves scenes")
end)

test("ALT+E2 on SETUP steps whole values", function()
  local context = load_strata(); finish_startup(context)
  -- SETUP: ALT+E2 (the MIDI port) stays in whole steps
  show_page("SETUP")
  params:set("midi_device", 1)
  key(1, 1); enc(2, 1); key(1, 0)
  assert_equal(params:get("midi_device"), 2, "ALT+E2 on SETUP steps the port")
end)

test("hot-plugged devices reach SETUP on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  context.grid.plug(1, 16, 16)
  context.midi.plug(1, "keys")
  local screen_shows, assert_drawn_on_next_frame = h.screen_shows, h.assert_drawn_on_next_frame
  show_page("SETUP")
  context.midi.unplug(1)
  assert_drawn_on_next_frame(context, arc_hardware, "midi.add", function() context.midi.plug(1, "pads") end)
  assert_true(screen_shows(context, "midi 1: pads"), "SETUP shows the new MIDI device")
  assert_drawn_on_next_frame(context, arc_hardware, "grid.add", function() context.grid.plug(2, 8, 8) end)
  assert_true(screen_shows(context, "grid: 2 connected"), "SETUP shows the second grid")
  assert_drawn_on_next_frame(context, arc_hardware, "grid.remove", function() context.grid.unplug(2) end)
  assert_true(screen_shows(context, "grid: 1 connected"), "SETUP shows the grid gone")
  assert_drawn_on_next_frame(context, nil, "arc.remove", function() context.arc.unplug(1) end)
  assert_true(screen_shows(context, "arc: none"), "SETUP shows the arc gone")
  local new_arc, arc_before_frame
  assert_drawn_on_next_frame(context, nil, "arc.add", function()
    new_arc = context.arc.plug(1); arc_before_frame = new_arc.refresh_count
  end)
  assert_true(screen_shows(context, "arc: connected"), "SETUP shows the new arc")
  assert_equal(arc_before_frame, 0, "arc.add: the new arc waits for the frame")
  assert_equal(new_arc.refresh_count, 1, "arc.add: the next frame draws the new arc once")
end)

test("SETUP saves once per K3 press; the release does nothing", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP"); context.clear_engine_calls()
  local saved = 0
  local real_save = save_scenes_to_disk
  save_scenes_to_disk = function() saved = saved + 1 end
  key(3, 1); key(3, 0)
  save_scenes_to_disk = real_save
  assert_equal(saved, 1, "SETUP K3 saves once per press")
end)

end

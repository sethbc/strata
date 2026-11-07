-- test/unit/pages_setup_test.lua
-- The SETUP page (lib/pages/setup.lua): its fields, status lines and keys
-- Run alone: lua test/run.lua pages_setup

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, next_frame = h.load_strata, h.local_value, h.next_frame
local finish_startup, show_page, assert_screen_layout = h.finish_startup, h.show_page, h.assert_screen_layout
local screen_shows, hint_text, tap = h.screen_shows, h.hint_text, h.tap

local function text_entry(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == text then return entry end
  end
end

test("SETUP lists the fields and E3 edits the one under the cursor", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP")
  params:set("midi_device", 1)
  enc(3, 1)
  assert_equal(params:get("midi_device"), 2, "cursor 1: the MIDI port")
  enc(2, 1); enc(3, 1)
  assert_equal(params:get("midi_channel_mode"), 2, "cursor 2: the channel mode")
  redraw()
  assert_true(screen_shows(context, "omni to selected"), "the channel mode's name is the value")
  enc(2, 1); enc(3, 1)
  assert_equal(params:get("mutation_enabled"), 1, "cursor 3: mutations on")
  redraw()
  assert_true(screen_shows(context, "on"), "shown as on")
  enc(2, 1); enc(3, 1)
  assert_true(math.abs(params:get("mutation_rate") - 2.1) < 1e-9, "cursor 4: the mutation rate steps 0.1")
  redraw()
  assert_true(screen_shows(context, "2.1 s"), "the rate shows its unit")
  enc(2, 1); enc(3, 1)
  assert_true(math.abs(params:get("mutation_probability") - 0.16) < 1e-9, "cursor 5: probability")
  enc(2, 1); enc(3, 1)
  assert_true(math.abs(params:get("mutation_amount") - 0.26) < 1e-9, "cursor 6: amount")
  enc(2, 1); enc(3, 1); enc(2, 1); enc(3, 1)
  assert_equal(params:get("midi_device"), 2, "E3 on save and load edits nothing")
  assert_equal(local_value("S").setup_cursor, 8, "the cursor stops on load scenes")
end)

test("SETUP shows the MIDI device and status lines", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP")
  assert_true(screen_shows(context, "midi 1: none"), "no device on port 1")
  context.midi.plug(1, "a very long controller name for the port")
  next_frame(context)
  local midi_line
  for _, entry in ipairs(context.screen.texts) do
    if entry.text:find("^midi 1: ") then midi_line = entry end
  end
  assert_true(midi_line ~= nil and midi_line.text ~= "midi 1: a very long controller name for the port",
    "the name is cut")
  local _, right = h.text_span(midi_line)
  assert_true(right <= 124, "the row ends by x 124")
  enc(2, 20); redraw()  -- the status lines are below the fields
  assert_true(screen_shows(context, "grid: 0 connected"), "no grid")
  assert_true(not text_entry(context, "16x8"), "no sizes line without a grid")
  context.grid.plug(1, 16, 8)
  next_frame(context)
  assert_true(screen_shows(context, "grid: 1 connected"), "one grid")
  assert_true(screen_shows(context, "16x8"), "its size")
  assert_true(screen_shows(context, "arc: none"), "no arc")
  context.arc.plug(1)
  next_frame(context)
  assert_true(screen_shows(context, "arc: connected"), "arc connected")
  local S = local_value("S")
  S.buffers[2].missing_path = "/gone/b.wav"
  S.buffers_restored = 1
  redraw()
  assert_true(screen_shows(context, "buffers: 1 ok, 1 missing"), "buffers missing")
  assert_screen_layout(context, "SETUP status lines")
end)

test("K3 on save and load runs them and does nothing elsewhere", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP")
  local scene_file = context.data_dir .. "strata/scenes.data"
  assert_true(not util.file_exists(scene_file), "no scenes file yet")
  tap(3)
  assert_true(not util.file_exists(scene_file), "K3 on the MIDI port does nothing")
  enc(2, 5); tap(3)
  assert_true(not util.file_exists(scene_file), "K3 on a mutation field does nothing")
  assert_equal(params:get("mutation_rate"), 2, "and changes no param")
  enc(2, 1); tap(3)
  assert_true(util.file_exists(scene_file), "K3 on save scenes writes the file")
  local loaded = 0
  local real_load = load_scenes_from_disk
  load_scenes_from_disk = function() loaded = loaded + 1 end
  enc(2, 1); tap(3)
  load_scenes_from_disk = real_load
  assert_equal(loaded, 1, "K3 on load scenes reads it back, once")
end)

test("SETUP scrolls with a marker and reaches both ends", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  show_page("SETUP")
  enc(2, 20)
  redraw()
  assert_equal(local_value("S").setup_cursor, 8, "the cursor is on load scenes")
  assert_true(screen_shows(context, "load scenes"), "load scenes is drawn")
  assert_true(screen_shows(context, "buffers: 0 restored"), "the last status line is drawn")
  assert_true(not text_entry(context, "midi port"), "the first fields scrolled out")
  assert_screen_layout(context, "SETUP scrolled to the end")
  enc(2, -20)
  redraw()
  assert_true(screen_shows(context, "midi 1: none"), "back at the top")
  assert_screen_layout(context, "SETUP scrolled to the start")
end)

test("SETUP hints", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP")
  assert_true(hint_text(context):find("E3:value", 1, true), "E3:value")
  assert_true(not hint_text(context):find("K3", 1, true), "no K3 on a value field")
  enc(2, 6); redraw()
  assert_true(hint_text(context):find("K3:save", 1, true), "K3:save on save scenes")
  enc(2, 1); redraw()
  assert_true(hint_text(context):find("K3:load", 1, true), "K3:load on load scenes")
end)

test("SETUP saves once per K3 press; the release does nothing", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP"); enc(2, 6)
  local saved = 0
  local real_save = save_scenes_to_disk
  save_scenes_to_disk = function() saved = saved + 1 end
  key(3, 1); key(3, 0)
  save_scenes_to_disk = real_save
  assert_equal(saved, 1, "SETUP K3 saves once per press")
end)

test("hot-plugged devices reach SETUP on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  context.grid.plug(1, 16, 16)
  context.midi.plug(1, "keys")
  local assert_drawn_on_next_frame = h.assert_drawn_on_next_frame
  show_page("SETUP")
  context.midi.unplug(1)
  assert_drawn_on_next_frame(context, arc_hardware, "midi.add", function() context.midi.plug(1, "pads") end)
  assert_true(screen_shows(context, "midi 1: pads"), "SETUP shows the new MIDI device")
  enc(2, 20); redraw()
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

end

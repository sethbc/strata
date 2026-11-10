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

test("every SETUP field shows its own label on its row", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP")
  enc(2, -20)
  local seen = 0
  while true do
    redraw()
    local field = S.lib.pages_setup.setup_rows()[S.setup_cursor]
    local selected = {}
    for _, entry in ipairs(context.screen.texts) do
      if entry.level == 15 and entry.y > 8 and entry.y < h.HINT_ROW_Y then table.insert(selected, entry) end
    end
    local label = selected[1]
    for _, entry in ipairs(selected) do
      if entry.x < label.x then label = entry end
    end
    assert_true(label.text:sub(1, #field.label) == field.label,
      "row " .. S.setup_cursor .. " starts with its label '" .. field.label .. "', not '" .. label.text .. "'")
    seen = seen + 1
    local before = S.setup_cursor
    enc(2, 1)
    if S.setup_cursor == before then break end
  end
  assert_equal(seen, 9, "the nine fields (no buffer length on the standard setting)")
end)

test("SETUP's save and load fields run the function their record holds", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP")
  local ran = {}
  for _, field in ipairs(S.lib.pages_setup.SETUP_FIELDS) do
    if field.kind == "action" then
      assert_equal(type(field.run), "function", field.label .. " holds its function")
      assert_equal(field.action, nil, field.label .. " names no global")
      local real = field.run
      field.run = function() ran[#ran + 1] = field.label end
      enc(2, -20)
      while S.lib.pages_setup.setup_rows()[S.setup_cursor] ~= field do enc(2, 1) end
      tap(3)
      field.run = real
    end
  end
  assert_equal(table.concat(ran, ","), "save scenes,load scenes", "K3 runs each field's own function")
end)

test("SETUP scrolls with a marker and reaches both ends", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  show_page("SETUP")
  enc(2, 20)
  redraw()
  assert_equal(local_value("S").setup_cursor, 9, "the cursor is on performance, the last field")
  assert_true(screen_shows(context, "load scenes"), "load scenes is drawn")
  assert_true(screen_shows(context, "buffers: 0 restored"), "the last status line is drawn")
  assert_true(not text_entry(context, "midi 1: none"), "the first fields scrolled out")
  local marker_bottom
  for _, line in ipairs(context.screen.lines) do
    if line.x1 == 127 and line.x2 == 127 then marker_bottom = math.max(line.y1, line.y2) end
  end
  assert_equal(marker_bottom, 55, "the marker's bottom is at the list's bottom")
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

-- The performance fields: the setting in performance.data (S.lib.performance),
-- never a param
local function entry_named(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == text then return entry end
  end
end

-- The other text on the label's row (the value, right-aligned at x 124)
local function value_beside(context, label)
  local label_entry = entry_named(context, label)
  if not label_entry then return nil end
  for _, entry in ipairs(context.screen.texts) do
    if entry ~= label_entry and entry.y == label_entry.y then return entry.text end
  end
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function write_file(path, text)
  os.execute("mkdir -p '" .. path:match("^(.*)/") .. "'")
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

-- Load with an active file (the engine's) and a setting file (Lua's), and
-- show SETUP scrolled to its last field
local function load_setup(active, setting_text)
  if active then h.write_performance_active(active) end
  local context = load_strata({ before_init = function(context)
    if setting_text then write_file(context.data_dir .. "strata/performance.data", setting_text) end
  end })
  finish_startup(context)
  show_page("SETUP"); enc(2, 20); redraw()
  return context
end

test("a setting that could not be saved shows the old value and says so", function()
  local context = load_setup()
  h.with_failing_setting_write("open", function()
    enc(3, 1); redraw()
  end)
  assert_equal(hint_text(context), "setting not saved", "the hint row says so")
  assert_equal(value_beside(context, "performance"), "auto", "the old value shows")
  assert_true(not screen_shows(context, "(next start)"), "nothing waits for the next start")
end)

local HIGH_60 = {tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60, reason = "high: setting"}

test("SETUP shows the setting, (next start) and the running tier", function()
  local context = load_setup()
  assert_equal(value_beside(context, "performance"), "auto", "the setting: auto by default")
  assert_true(screen_shows(context, "running: standard"), "the running tier")
  assert_true(not screen_shows(context, "(next start)"), "the setting is what this start used")
  assert_screen_layout(context, "SETUP performance auto")
  enc(3, 2); redraw()
  assert_equal(value_beside(context, "performance"), "high", "E3 steps to high")
  assert_true(screen_shows(context, "(next start)"), "high applies at the next start")
  assert_true(screen_shows(context, "running: standard"), "standard still runs")
  assert_true(entry_named(context, "(next start)").x > 0, "the note is indented under the field")
  assert_screen_layout(context, "SETUP performance high (next start)")
  enc(3, -1); redraw()
  assert_equal(value_beside(context, "performance"), "standard")
  assert_true(screen_shows(context, "(next start)"), "standard differs from auto too")
  enc(3, -5); redraw()
  assert_equal(value_beside(context, "performance"), "auto", "clamped at auto")
  assert_true(not screen_shows(context, "(next start)"), "back to the setting this start used")
  -- a high start
  context = load_setup(HIGH_60, "performance high\nbuffer_seconds 60\n")
  assert_equal(value_beside(context, "performance"), "high")
  assert_true(screen_shows(context, "running: high, 60 s"), "the running tier and its length")
  assert_true(not screen_shows(context, "(next start)"), "nothing waits for the next start")
  assert_screen_layout(context, "SETUP performance high")
end)

test("the buffer length field shows only for the high setting or tier", function()
  local context = load_setup()
  assert_true(not screen_shows(context, "buffer length"), "auto on standard: no buffer length")
  enc(3, 2); redraw()
  assert_equal(value_beside(context, "buffer length"), "60 s", "the high setting offers it")
  enc(2, 1); enc(3, 1); redraw()
  assert_equal(value_beside(context, "buffer length"), "120 s", "E3 steps 60 -> 120")
  assert_true(screen_shows(context, "(next start)"), "the new length waits for the next start")
  enc(3, 5); redraw()
  assert_equal(value_beside(context, "buffer length"), "300 s", "clamped at 300")
  enc(3, -9); redraw()
  assert_equal(value_beside(context, "buffer length"), "16 s", "clamped at 16")
  assert_screen_layout(context, "SETUP buffer length")
  -- the running tier is high and the setting auto (a Pi 4)
  context = load_setup({tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60,
    reason = "auto: Raspberry Pi 4 Model B Rev 1.4"})
  assert_equal(value_beside(context, "performance"), "auto")
  assert_equal(value_beside(context, "buffer length"), "60 s", "the high tier offers it")
  -- the memory step-down
  context = load_setup({tier = "high", buffer_seconds = 120, max_grains = 128, history_seconds = 60,
    reason = "high: setting; buffer 300 s -> 120 s (memory)"}, "performance high\nbuffer_seconds 300\n")
  assert_equal(value_beside(context, "buffer length"), "300 s", "the setting")
  assert_true(screen_shows(context, "300 s -> 120 s (memory)"), "memory stepped it down")
  assert_true(screen_shows(context, "running: high, 120 s"), "what runs")
  assert_screen_layout(context, "SETUP memory step-down")
  -- standard: the setting says standard and so does the tier
  context = load_setup(nil, "performance standard\nbuffer_seconds 300\n")
  assert_equal(value_beside(context, "performance"), "standard")
  assert_true(not screen_shows(context, "buffer length"), "no buffer length on standard")
end)

test("SETUP shows why the running tier is not the setting's", function()
  local context = load_setup({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "standard: performance_active.data could not be written"})
  local running = entry_named(context, "running: standard")
  local note = entry_named(context, "active file not written")
  assert_true(running and note, "the running row and its note show")
  assert_true(note.y > running.y and note.y - running.y <= 10, "the note is directly under running")
  assert_screen_layout(context, "SETUP running note at the end")
  enc(2, -20); redraw()
  assert_screen_layout(context, "SETUP running note at the start")
  context = load_setup({tier = "high", buffer_seconds = 16, max_grains = 128, history_seconds = 60,
    reason = "high: setting; buffer 300 s -> 16 s (meminfo unreadable)"}, "performance high\nbuffer_seconds 300\n")
  assert_true(screen_shows(context, "300 s -> 16 s (no meminfo)"), "the cause is named")
  -- a plain reason adds no note row
  context = load_setup({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "auto: Raspberry Pi 3"})
  local rows = local_value("S").lib.pages_setup.setup_rows()
  for _, row in ipairs(rows) do
    assert_true(row.text ~= "active file not written" and row.text ~= "old active file kept", "no note row")
  end
end)

test("high on a CM3 or Pi 3 warns may xrun", function()
  for _, platform in ipairs({ 2, 3 }) do
    local context = load_setup()
    norns.platform = platform
    redraw()
    assert_true(not screen_shows(context, "may xrun"), "auto never warns (platform " .. platform .. ")")
    enc(3, 2); redraw()
    assert_true(screen_shows(context, "(next start), may xrun"), "high warns on platform " .. platform)
    assert_screen_layout(context, "SETUP may xrun")
    enc(3, -1); redraw()
    assert_true(screen_shows(context, "(next start)"), "standard does not warn")
  end
  for _, platform in ipairs({ 0, 1, 4, 5, 6 }) do
    local context = load_setup(HIGH_60, "performance high\nbuffer_seconds 60\n")
    norns.platform = platform
    redraw()
    assert_true(not screen_shows(context, "may xrun"), "no warning on platform " .. platform)
  end
  local context = load_setup(HIGH_60, "performance high\nbuffer_seconds 60\n")
  norns.platform = 2; redraw()
  assert_true(screen_shows(context, "may xrun"), "a high start on a CM3 warns too")
end)

test("changing a SETUP field writes performance.data as key value lines", function()
  local context = load_setup()
  local path = context.data_dir .. "strata/performance.data"
  assert_equal(read_file(path), nil, "nothing written before a change")
  enc(3, 2); enc(2, 1); enc(3, 1)
  assert_equal(read_file(path), "performance high\nbuffer_seconds 120\n")
  enc(3, 1); enc(3, -1)
  assert_equal(read_file(path), "performance high\nbuffer_seconds 120\n", "rewritten on each change")
  enc(3, 9)
  assert_equal(read_file(path), "performance high\nbuffer_seconds 300\n")
  -- no param, PSET or scene holds either
  for id in pairs(params.lookup) do
    assert_true(not tostring(id):find("performance", 1, true) and not tostring(id):find("buffer_length", 1, true),
      "param " .. tostring(id))
  end
  capture_scene(1)
  local function holds(value, depth)
    if type(value) ~= "table" or depth > 8 then return false end
    for key, inner in pairs(value) do
      if key == "performance" or key == "buffer_seconds" or holds(inner, depth + 1) then return true end
    end
    return false
  end
  assert_true(local_value("S").scenes[1] ~= nil, "a scene was captured")
  assert_true(not holds(local_value("S").scenes[1], 1), "a captured scene holds neither")
  -- K3 on a performance field runs nothing
  local saved = 0
  local real_save = save_scenes_to_disk
  save_scenes_to_disk = function() saved = saved + 1 end
  tap(3)
  save_scenes_to_disk = real_save
  assert_equal(saved, 0, "K3 does nothing on a performance field")
  assert_true(not hint_text(context):find("K3", 1, true), "and its hints offer no K3")
end)

end

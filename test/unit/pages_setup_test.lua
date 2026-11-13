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
  enc(2, 4); enc(3, 1)  -- past 3.5's note off, mpe & zones and note pool
  assert_equal(params:get("mutation_enabled"), 1, "cursor 6: mutations on")
  redraw()
  assert_true(screen_shows(context, "on"), "shown as on")
  enc(2, 1); enc(3, 1)
  assert_true(math.abs(params:get("mutation_rate") - 2.1) < 1e-9, "cursor 7: the mutation rate steps 0.1")
  redraw()
  assert_true(screen_shows(context, "2.1 s"), "the rate shows its unit")
  enc(2, 1); enc(3, 1)
  assert_true(math.abs(params:get("mutation_probability") - 0.16) < 1e-9, "cursor 8: probability")
  enc(2, 1); enc(3, 1)
  assert_true(math.abs(params:get("mutation_amount") - 0.26) < 1e-9, "cursor 9: amount")
  enc(2, 1); enc(3, 1); enc(2, 1); enc(3, 1)
  assert_equal(params:get("midi_device"), 2, "E3 on save and load edits nothing")
  assert_equal(local_value("S").setup_cursor, 11, "the cursor stops on load scenes")
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
  enc(2, 60); redraw()  -- the status lines are below the fields
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
  enc(2, 60); redraw()  -- the rows grew: scroll on to the end
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
  enc(2, 8); tap(3)
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
  assert_equal(seen, 17, "the seventeen fields: thirteen, and four grid rotations (no buffer length on the standard setting)")
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
  assert_equal(table.concat(ran, ","), "mpe & zones,save scenes,load scenes", "K3 runs each field's own function")
end)

test("SETUP scrolls with a marker and reaches both ends", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  show_page("SETUP")
  enc(2, 16)
  redraw()
  assert_equal(local_value("S").setup_cursor, 17, "the cursor is on performance, the last field")
  assert_true(screen_shows(context, "grid 4 rotation"), "the field above it, grid 4 rotation, is drawn")
  assert_true(not screen_shows(context, "buffers: 0 restored"), "the last status line is below the view")
  enc(2, 20)  -- E2 on the last field scrolls over the status rows (#319)
  redraw()
  assert_equal(local_value("S").setup_cursor, 17, "the cursor stays on performance")
  assert_true(screen_shows(context, "buffers: 0 restored"), "the last status line is drawn")
  assert_true(not text_entry(context, "midi 1: none"), "the first fields scrolled out")
  local marker_bottom
  for _, line in ipairs(context.screen.lines) do
    if line.x1 == 127 and line.x2 == 127 then marker_bottom = math.max(line.y1, line.y2) end
  end
  assert_equal(marker_bottom, 54, "the marker's bottom is at the list's bottom")
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
  enc(2, 9); redraw()
  assert_equal(hint_text(context), "E2:field K3:save", "an action row: no E3:value, which does nothing there (#420)")
  enc(2, 1); redraw()
  assert_equal(hint_text(context), "E2:field K3:load", "K3:load on load scenes")
  -- with ALT held no K3 is offered: ALT+K3 does nothing on SETUP (#419)
  key(1, 1); redraw()
  assert_true(not hint_text(context):find("K3", 1, true), "ALT on an action row names no K3: " .. tostring(hint_text(context)))
  enc(2, -20); enc(2, 6); redraw()
  assert_equal(hint_text(context), "E2:field E3:fine", "ALT on a value field offers the fine turn")
  key(1, 0)
end)

-- E2 past the last field scrolls the view off it (#319): E3 there must not
-- edit a field the player cannot see, so it scrolls back instead
local function every_param_value()
  local values = {}
  for _, param in ipairs(params.params) do
    if param.id then values[param.id] = params:get(param.id) end
  end
  return values
end

local function scrolled_off_the_last_field(context)
  local S = local_value("S")
  S.scene_file.problem = "unreadable"   -- one unreadable scenes file: two more rows below
  show_page("SETUP")
  enc(2, 60); redraw()
  assert_equal(S.setup_cursor, 17, "the cursor is on performance, the last field")
  assert_true(not text_entry(context, "performance"), "the performance row has scrolled out of view")
  return S
end

test("SETUP's E3 edits nothing while the view is scrolled past the cursor's field", function()
  local context = load_strata(); finish_startup(context)
  local S = scrolled_off_the_last_field(context)
  local before, buffer_seconds = every_param_value(), S.lib.performance.setting().buffer_seconds
  enc(3, 1)
  assert_equal(S.lib.performance.setting().performance, "auto", "the performance setting is unchanged")
  assert_equal(S.lib.performance.setting().buffer_seconds, buffer_seconds, "and so is the buffer length")
  for id, value in pairs(every_param_value()) do assert_equal(value, before[id], "param " .. id .. " is unchanged") end
end)

test("SETUP's E3 while scrolled brings the cursor's field back; the next E3 edits it", function()
  local context = load_strata(); finish_startup(context)
  local S = scrolled_off_the_last_field(context)
  enc(3, -1); redraw()
  assert_true(text_entry(context, "performance") ~= nil, "the performance row is back in view")
  assert_equal(S.setup_cursor, 17, "the cursor stays on performance")
  enc(3, 1)
  assert_equal(S.lib.performance.setting().performance, "standard", "with the field in view E3 edits it")
end)

test("SETUP's hint names no E3 value while the view is scrolled past the cursor's field", function()
  local context = load_strata(); finish_startup(context)
  scrolled_off_the_last_field(context)
  assert_true(not hint_text(context):find("E3:value", 1, true), "no E3:value: " .. tostring(hint_text(context)))
  assert_equal(hint_text(context), "E2:field E3:back", "E3 scrolls back to the field")
  assert_screen_layout(context, "SETUP scrolled past the last field")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "E2:field", "ALT: no fine turn either")
  key(1, 0)
  enc(3, 1); redraw()
  assert_equal(hint_text(context), "E2:field E3:value", "back on the field: E3 edits it again")
end)

test("SETUP saves once per K3 press; the release does nothing", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP"); enc(2, 9)
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
  show_page("SETUP"); enc(2, 60); redraw()
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
  local with_note_rows = #local_value("S").lib.pages_setup.setup_rows()
  local spacing = local_value("S").lib.pages_setup.SETUP_PAGE.spacing
  assert_true(note.y > running.y and note.y - running.y == spacing,
    "the note is directly under running")
  assert_screen_layout(context, "SETUP running note at the end")
  enc(2, -20); redraw()
  assert_screen_layout(context, "SETUP running note at the start")
  context = load_setup({tier = "high", buffer_seconds = 16, max_grains = 128, history_seconds = 60,
    reason = "high: setting; buffer 300 s -> 16 s (meminfo unreadable)"}, "performance high\nbuffer_seconds 300\n")
  assert_true(screen_shows(context, "300 s -> 16 s (meminfo)"), "the cause is named")
  assert_screen_layout(context, "SETUP meminfo step-down")
  -- a plain reason adds no note row
  context = load_setup({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "auto: Raspberry Pi 3"})
  local rows = local_value("S").lib.pages_setup.setup_rows()
  assert_equal(#rows + 1, with_note_rows, "the note adds exactly one row")
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

-- The data files on SETUP (#301)

local write_text = h.write_text

-- The cursor on `label`'s field
local function cursor_on(label)
  local S = local_value("S")
  enc(2, -20)
  while S.lib.pages_setup.setup_rows()[S.setup_cursor].label ~= label do
    local before = S.setup_cursor
    enc(2, 1)
    if S.setup_cursor == before then error("no field " .. label, 2) end
  end
end

-- The status rows' texts, joined by "|"
local function status_texts()
  local texts = {}
  for _, row in ipairs(local_value("S").lib.pages_setup.setup_rows()) do
    if row.selectable == false then texts[#texts + 1] = row.text end
  end
  return table.concat(texts, "|")
end

-- 3.4 (design 8.11): the transport row is seq_follow_transport, shown as
-- follow or off
test("SETUP's transport row shows follow or off and E3 turns following the transport off and on", function()
  local context = load_strata(); finish_startup(context)
  show_page("SETUP")
  cursor_on("transport"); redraw()
  assert_equal(params:get("seq_follow_transport"), 1, "on by default")
  assert_equal(value_beside(context, "transport"), "follow", "shown as follow")
  assert_equal(hint_text(context), "E2:field E3:value", "the hints")
  enc(3, -1); redraw()
  assert_equal(params:get("seq_follow_transport"), 0, "E3 left: off")
  assert_equal(value_beside(context, "transport"), "off", "shown as off")
  enc(3, 1); redraw()
  assert_equal(params:get("seq_follow_transport"), 1, "E3 right: on again")
  assert_equal(value_beside(context, "transport"), "follow", "follow again")
  assert_screen_layout(context, "SETUP transport row")
end)

test("K3 on save scenes and load scenes says what it did on SETUP's hint row (#463)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata/scenes.data"
  show_page("SETUP")
  cursor_on("load scenes"); tap(3)
  assert_equal(S.lib.ui_flash.text("hints"), "no scenes file")
  next_frame(context)
  assert_equal(hint_text(context), "no scenes file", "on the hint row")
  cursor_on("save scenes"); tap(3)
  assert_equal(S.lib.ui_flash.text("hints"), "scenes saved")
  assert_true(util.file_exists(path))
  cursor_on("load scenes"); tap(3)
  assert_equal(S.lib.ui_flash.text("hints"), "scenes loaded")
  write_text(path, "return {")
  tap(3)
  assert_equal(S.lib.ui_flash.text("hints"), "scenes unreadable")
  -- a save that cannot write (its .part is a folder that holds a file)
  os.execute("mkdir -p '" .. path .. ".part/inside'")
  cursor_on("save scenes"); tap(3)
  assert_equal(S.lib.ui_flash.text("hints"), "scenes not saved")
  next_frame(context)
  assert_screen_layout(context, "SETUP scenes not saved flash")
  -- the flash is SETUP's: it does not show over another page's keys
  show_page("MAIN")
  assert_equal(S.lib.ui_flash.text("hints"), nil, "SETUP's flash is not shown on MAIN")
end)

test("SETUP asks for a second K3 before a load drops a scene that is not on disk (#328)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local path = context.data_dir .. "strata/scenes.data"
  S.lib.scenes.save(1)
  os.execute("mkdir -p '" .. path .. ".part/inside'")  -- the next write fails
  S.lib.scenes.save(2)
  assert_equal(S.lib.ui_flash.text("header"), "S2 not on disk")
  show_page("SETUP")
  cursor_on("load scenes")
  tap(3)
  assert_true(S.scenes[2].populated, "one K3 leaves the scene that is not on disk")
  assert_equal(S.lib.ui_flash.text("hints"), "K3 again: drop unsaved")
  next_frame(context)
  assert_equal(hint_text(context), "K3 again: drop unsaved", "the prompt is on the hint row")
  assert_screen_layout(context, "SETUP load prompt")
  context.clock.run_for(1.9)
  assert_equal(S.lib.ui_flash.text("hints"), "K3 again: drop unsaved", "for the 2 s the second K3 has")
  tap(3)
  assert_true(not S.scenes[2].populated, "the second K3 loads the file")
  assert_true(S.scenes[1].populated, "with the scene it holds")
  assert_equal(S.lib.ui_flash.text("hints"), "scenes loaded")
  -- nothing unsaved now: one K3 loads
  context.clock.run_for(3)
  tap(3)
  assert_equal(S.lib.ui_flash.text("hints"), "scenes loaded")
end)

test("SETUP lists a data file it could not read or write, and where an unreadable one was kept (#463)", function()
  local data_root = h.data_root
  -- both files unreadable and kept: each names its backup
  local subdir = "setup-unreadable-" .. math.random(1, 1e9)
  local dir = data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "'")
  write_text(dir .. "scenes.data", "return {"); write_text(dir .. "scenes.data.bak", "an earlier backup")
  write_text(dir .. "buffers.data", "return {")
  local context = load_strata({ data_subdir = subdir }); finish_startup(context)
  assert_true(status_texts():find("scenes unreadable, kept|as scenes.data.bak.2|buffers unreadable, kept|"
    .. "as buffers.data.bak", 1, true) ~= nil, status_texts())
  show_page("SETUP"); enc(2, 60); redraw()
  for _, text in ipairs({ "scenes unreadable, kept", "as scenes.data.bak.2", "buffers unreadable, kept",
      "as buffers.data.bak" }) do
    assert_true(screen_shows(context, text), "drawn at the end of the list: " .. text)
  end
  assert_screen_layout(context, "SETUP data files unreadable")
  -- unreadable and not moved (every backup name taken): still in place, not saved over
  subdir = "setup-in-place-" .. math.random(1, 1e9)
  dir = data_root .. subdir .. "/strata/"
  os.execute("mkdir -p '" .. dir .. "scenes.data.bak'")
  for number = 2, 9 do os.execute("mkdir -p '" .. dir .. "scenes.data.bak." .. number .. "'") end
  write_text(dir .. "scenes.data", "return {")
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  local S = local_value("S")
  assert_true(status_texts():find("scenes file unreadable|not saved over", 1, true) ~= nil, status_texts())
  S.lib.scenes.save(3)
  assert_equal(S.lib.ui_flash.text("header"), "S3 not on disk", "the autosave is blocked")
  -- a write that failed
  subdir = "setup-not-saved-" .. math.random(1, 1e9)
  dir = data_root .. subdir .. "/strata/"
  context = load_strata({ data_subdir = subdir }); finish_startup(context)
  S = local_value("S")
  os.execute("mkdir -p '" .. dir .. "scenes.data.part/inside'")
  os.execute("mkdir -p '" .. dir .. "buffers.data.part/inside'")
  S.lib.scenes.save(1)
  load_buffer(1, "/tmp/one.wav")
  context.clock.run_for(0.11)   -- buffers.data is written 0.1 s after the change (#566)
  assert_true(status_texts():find("scenes file not saved|buffers file not saved", 1, true) ~= nil, status_texts())
  show_page("SETUP"); enc(2, 60); redraw()
  assert_true(screen_shows(context, "scenes file not saved") and screen_shows(context, "buffers file not saved"))
  -- the next writes that work clear both
  os.remove(dir .. "scenes.data.part/inside"); os.remove(dir .. "scenes.data.part")
  os.remove(dir .. "buffers.data.part/inside"); os.remove(dir .. "buffers.data.part")
  S.lib.scenes.save(1); load_buffer(2, "/tmp/two.wav")
  context.clock.run_for(0.11)
  assert_true(not status_texts():find("not saved", 1, true), status_texts())
end)


-- #323: a rotation per grid port (S.lib.grid_core.set_rotation), kept in
-- grids.data; 90 or 270 stands a 128 upright as the 8x16
test("SETUP's grid rotation fields turn each port's grid (#323)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local core = S.lib.grid_core
  local device = context.grid.plug(1, 16, 8)
  show_page("SETUP")
  for port = 1, 4 do
    cursor_on("grid " .. port .. " rotation"); redraw()
    assert_equal(value_beside(context, "grid " .. port .. " rotation"), "0", "port " .. port .. " at 0")
    assert_equal(hint_text(context), "E2:field E3:value", "the hints")
  end
  cursor_on("grid 1 rotation")
  enc(3, 1); redraw()
  assert_equal(core.rotation(1), 1, "E3 right: rotation 1")
  assert_equal(value_beside(context, "grid 1 rotation"), "90", "shown as 90")
  assert_equal(device.rotation_value, 1, "the grid is turned")
  assert_equal(core.layout_of(1), S.registry.grid_layouts["128v"], "a 16x8 turned is the 8x16 layout")
  enc(3, 5); redraw()
  assert_equal(value_beside(context, "grid 1 rotation"), "270", "clamped at 270")
  enc(3, -1); redraw()
  assert_equal(value_beside(context, "grid 1 rotation"), "180")
  assert_equal(core.layout_of(1), S.registry.grid_layouts["128h"], "180 is the 16x8 again")
  enc(3, -5); redraw()
  assert_equal(value_beside(context, "grid 1 rotation"), "0", "clamped at 0")
  enc(2, 20); redraw()
  assert_true(screen_shows(context, "16x8"), "the sizes line")
  cursor_on("grid 1 rotation"); enc(3, 1)
  enc(2, 20); redraw()
  assert_true(screen_shows(context, "8x16"), "the sizes line follows the rotation")
  cursor_on("grid 3 rotation"); enc(3, 2); redraw()
  assert_equal(value_beside(context, "grid 3 rotation"), "180", "a port with no grid keeps a setting")
  assert_equal(core.rotation(3), 2)
  assert_screen_layout(context, "SETUP grid rotations")
end)

test("a grid rotation that cannot be saved keeps its value and says so", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local device = context.grid.plug(1, 16, 8)
  os.execute("mkdir -p '" .. context.data_dir .. "strata/grids.data.part/inside'")
  show_page("SETUP"); cursor_on("grid 1 rotation")
  enc(3, 1); next_frame(context)
  assert_equal(S.lib.grid_core.rotation(1), 0, "not set")
  assert_equal(device.rotation_value, 0, "the grid is not turned")
  assert_equal(hint_text(context), "setting not saved", "the hint row says so")
  assert_equal(value_beside(context, "grid 1 rotation"), "0", "the old value shows")
end)

-- #319: every row of the list is drawn at some E2 position, whatever notes,
-- grids and problems stack up below the last field
local function assert_every_row_reachable(context, where)
  local S = local_value("S")
  local rows = S.lib.pages_setup.setup_rows()
  local drawn = {}
  show_page("SETUP")
  enc(2, -100)
  for _ = 1, #rows + 8 do
    redraw()
    for _, entry in ipairs(context.screen.texts) do drawn[entry.text] = true end
    enc(2, 1)
  end
  for _, row in ipairs(rows) do
    if row.selectable == false then
      assert_true(drawn[row.text], "'" .. row.text .. "' is drawn at some E2 position (" .. where .. ")")
    end
  end
end

test("every status row of SETUP can be scrolled into view, with notes, grids and problems (#319)", function()
  local context = load_strata(); finish_startup(context)
  assert_every_row_reachable(context, "plain")
  -- a grid and one note row: the buffers row was cut off
  context.grid.plug(1, 16, 16)
  norns.platform = 2
  local S = local_value("S")
  S.performance_setting = {performance = "high", buffer_seconds = 300}
  assert_every_row_reachable(context, "grid, may xrun and next start")
  -- the most rows: two grids, an arc, the step-down, a running note, four problem rows
  context.grid.plug(2, 16, 8); context.arc.plug(1)
  S.performance = {tier = "high", buffer_seconds = 120, max_grains = 128, history_seconds = 60,
    reason = "high: setting; the active file could not be written"}
  S.performance_start_setting = {performance = "high", buffer_seconds = 300}
  S.scene_file.problem, S.scene_file.backup = "unreadable", "/x/scenes.data.bak"
  S.buffer_file.problem, S.buffer_file.backup = "unreadable", "/x/buffers.data.bak"
  assert_every_row_reachable(context, "everything")
  redraw()
  assert_screen_layout(context, "SETUP scrolled over every row")
end)

test("SETUP's data file problems follow buffers:, as the design places them (#301)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.scene_file.problem, S.scene_file.backup = "unreadable", "/x/scenes.data.bak"
  S.buffer_file.problem = "not saved"
  local texts = {}
  for _, row in ipairs(S.lib.pages_setup.setup_rows()) do texts[#texts + 1] = row.text or row.label end
  local joined = table.concat(texts, "|")
  assert_true(joined:find("buffers: 0 restored|scenes unreadable, kept|as scenes.data.bak|buffers file not saved",
    1, true), joined)
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
-- so E3 on the mutations row sets its binary param through set_binary_param
-- (lib/ui/params.lua), and a controller mapped to it in PARAMS > MAP
-- follows. The map is as lua/core/pmap.lua's pmap.new makes it, echo on
test("E3 on SETUP's mutations row echoes to a MIDI-mapped controller (#538)", function()
  local context = load_strata(); finish_startup(context)
  local controller = context.midi.plug(1)
  norns.pmap.data.mutation_enabled = { dev = 1, ch = 1, cc = 44, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1,
    echo = true, value = 0 }
  show_page("SETUP")
  enc(2, 5)   -- mutations
  enc(3, 1)
  assert_equal(params:get("mutation_enabled"), 1, "E3 right turns mutations on")
  enc(3, -1)
  assert_equal(params:get("mutation_enabled"), 0, "E3 left turns them off")
  assert_equal(cc_echoes(controller, 44), "127,0", "the controller hears both")
end)


-- 3.5 (design 9.3, ruling 10): note off, mpe & zones and note pool follow
-- channels and are always there, so no field moves when the mode changes
local function field_labels(count)
  local labels = {}
  for _, row in ipairs(local_value("S").lib.pages_setup.setup_rows()) do
    if row.selectable ~= false and #labels < count then labels[#labels + 1] = row.label end
  end
  return table.concat(labels, ", ")
end

test("note off, mpe & zones and note pool follow channels, whatever the mode", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local expected = "midi, channels, note off, mpe & zones, note pool, mutations, mutation rate"
  for mode = 1, #S.lib.midi_in.MIDI.channel_mode_options do
    params:set("midi_channel_mode", mode)
    assert_equal(field_labels(7), expected, "the same fields in channel mode " .. mode)
  end
  params:set("midi_channel_mode", 1)
  show_page("SETUP")
  enc(2, 2); redraw()  -- note off
  assert_equal(value_beside(context, "note off"), params:string("midi_note_off"), "the param's own option name")
  assert_equal(hint_text(context), "E2:field E3:value")
  local before = params:get("midi_note_off")
  enc(3, 1)
  assert_equal(params:get("midi_note_off"), before + 1, "E3 steps midi_note_off")
  enc(2, 1); redraw()
  assert_equal(hint_text(context), "E2:field K3:edit", "mpe & zones is an action row")
  assert_equal(value_beside(context, "mpe & zones"), nil, "with no value")
  enc(3, 1)
  assert_true(not S.lib.ui_zones.is_open(), "E3 opens nothing")
  enc(2, 1); redraw()
  assert_equal(value_beside(context, "note pool"), tostring(S.lib.notes.pool()), "the pool")
  assert_equal(hint_text(context), "E2:field E3:value")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "E2:field", "no fine turn on the pool")
  key(1, 0)
  assert_screen_layout(context, "SETUP's note rows")
end)

test("note pool steps the device setting and marks standard above its default", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local notes, NOTE_POOL = S.lib.notes, S.constants.NOTE_POOL
  local spacing = S.lib.pages_setup.SETUP_PAGE.spacing
  assert_equal(S.performance.tier, "standard")
  show_page("SETUP"); cursor_on("note pool"); redraw()
  assert_equal(notes.pool(), NOTE_POOL.standard, "the standard tier's default")
  assert_equal(value_beside(context, "note pool"), tostring(NOTE_POOL.standard))
  assert_true(not screen_shows(context, "may xrun"), "no note at the default")
  context.clear_engine_calls()
  enc(3, 1); redraw()
  assert_equal(notes.pool(), NOTE_POOL.standard + 1, "E3 +1 steps the pool")
  assert_equal(value_beside(context, "note pool"), tostring(NOTE_POOL.standard + 1))
  assert_equal(#context.calls_named("setNotePool"), 1, "the engine has it")
  local note, field = entry_named(context, "may xrun"), entry_named(context, "note pool")
  assert_true(note ~= nil, "a pool above standard's default may xrun")
  assert_equal(note.level, 4, "a dim note")
  assert_equal(note.x, S.lib.pages_setup.SETUP_PAGE.note_indent, "indented")
  assert_equal(note.y - field.y, spacing, "directly under the field")
  assert_equal(S.lib.pages_setup.setup_rows()[S.setup_cursor].label, "note pool", "the cursor stays on the pool")
  assert_screen_layout(context, "SETUP note pool may xrun")
  enc(2, 1)
  assert_equal(S.lib.pages_setup.setup_rows()[S.setup_cursor].label, "mutations", "E2 steps over the note")
  enc(2, -1)
  enc(3, 30); redraw()
  assert_equal(notes.pool(), NOTE_POOL.max, "clamped at the maximum")
  assert_equal(value_beside(context, "note pool"), tostring(NOTE_POOL.max))
  assert_screen_layout(context, "SETUP note pool at its maximum")
  enc(3, -30); redraw()
  assert_equal(notes.pool(), 0, "clamped at 0")
  assert_true(not screen_shows(context, "may xrun"), "no note at 0")
  context.clear_engine_calls()
  enc(3, -1)
  assert_equal(#context.calls_named("setNotePool"), 0, "nothing sent at the end of the range")
  -- a write that fails keeps the pool and says so
  os.execute("mkdir -p '" .. context.data_dir .. "strata/notes.data.part/inside'")
  enc(3, 1); next_frame(context)
  assert_equal(notes.pool(), 0, "not set")
  assert_equal(hint_text(context), "setting not saved", "the hint row says so")
  assert_equal(value_beside(context, "note pool"), "0", "the old value shows")
  -- the high tier: no note at any pool
  context = load_setup(HIGH_60, "performance high\nbuffer_seconds 60\n")
  S = local_value("S")
  assert_equal(S.lib.notes.pool(), NOTE_POOL.high, "the high tier's default")
  cursor_on("note pool")
  enc(3, 30); redraw()
  assert_equal(S.lib.notes.pool(), NOTE_POOL.max)
  for _, row in ipairs(S.lib.pages_setup.setup_rows()) do
    assert_true(row.text ~= "may xrun", "no may xrun under the pool on high")
  end
end)

test("K3 on mpe & zones opens the editor, and K2 closes it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP"); cursor_on("mpe & zones")
  local cursor = S.setup_cursor
  assert_true(not S.lib.ui_zones.is_open(), "closed")
  tap(3)
  assert_true(S.lib.ui_zones.is_open(), "K3 opens the editor")
  next_frame(context)
  assert_true(screen_shows(context, "lower members"), "its rows")
  assert_true(not screen_shows(context, "mpe & zones"), "over SETUP's")
  assert_screen_layout(context, "SETUP's zones editor")
  tap(2)
  assert_true(not S.lib.ui_zones.is_open(), "K2 closes it")
  next_frame(context)
  assert_true(screen_shows(context, "mpe & zones"), "SETUP shows again")
  assert_equal(S.setup_cursor, cursor, "on the row it opened from")
end)

end

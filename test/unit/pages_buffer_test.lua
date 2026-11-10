-- test/unit/pages_buffer_test.lua
-- The BUFFER page (lib/pages/buffer.lua): the slot and field cursors, its
-- rows, keys, flashes, the input meter and the file selector
-- Run alone: lua test/run.lua pages_buffer

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap, hint_text, texts_on_row = h.tap, h.hint_text, h.texts_on_row

-- The header's page dots (lib/ui/header.lua): its 2x2 rects above y 9
local function page_dots(context)
  local dots = {}
  for _, rect in ipairs(context.screen.rects) do
    if rect.y + rect.h <= 9 and rect.w == 2 and rect.h == 2 then table.insert(dots, rect) end
  end
  return dots
end

-- ALT (K1 held) around a call
local function with_alt(fn)
  key(1, 1); fn(); key(1, 0)
end

-- The slot rows drawn: slot number -> the row's y (the slot numbers at
-- BUFFER_PAGE.slot_x, between the header and the hint row)
local function slot_rows(context)
  local page = local_value("BUFFER_PAGE")
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == page.slot_x and entry.align == "left" and entry.y > 8 and entry.y < HINT_ROW_Y then
      rows[tonumber(entry.text)] = entry.y
    end
  end
  return rows
end

-- The right column's strings on row y, left to right, joined by spaces
local function slot_row_text(context, y)
  local page = local_value("BUFFER_PAGE")
  local parts = {}
  for _, entry in ipairs(texts_on_row(context, y)) do
    if select(1, text_span(entry)) >= page.slot_x then table.insert(parts, entry.text) end
  end
  return table.concat(parts, " ")
end

-- The left column's visible field rows, top to bottom: {label, value,
-- level, cursor, y}. A label may be cut to fit beside a wide value (the
-- layout estimate is wider than the norns font), so field_named matches a
-- label by its start
local function field_rows(context)
  local page = local_value("BUFFER_PAGE")
  local rows = {}
  for index = 1, page.field_visible do
    local y = page.field_first_y + (index - 1) * page.field_spacing
    local row = { y = y }
    for _, entry in ipairs(texts_on_row(context, y)) do
      if entry.x < page.divider_x then
        if entry.text == ">" then row.cursor = true
        elseif entry.x == page.label_x and entry.align == "left" then row.label = entry.text; row.level = entry.level
        elseif entry.align == "right" then row.value = entry.text end
      end
    end
    if row.label then table.insert(rows, row) end
  end
  return rows
end

local function field_named(context, label)
  for _, row in ipairs(field_rows(context)) do
    if #row.label >= 2 and label:sub(1, #row.label) == row.label then return row end
  end
  return {}
end

local function field_labels(context)
  local labels = {}
  for _, row in ipairs(field_rows(context)) do table.insert(labels, row.label) end
  return table.concat(labels, " ")
end

-- Move the field cursor to field n (1-based) with ALT+E2
local function to_field(n)
  key(1, 1); enc(2, -20); enc(2, n - 1); key(1, 0)
end

-- The input meter's segments: the count drawn at the lit level and the
-- segment index drawn at the peak level (nil when none)
local function meter_state(context)
  local page = local_value("BUFFER_PAGE")
  local lit, peak, segments = 0, nil, 0
  for _, rect in ipairs(context.screen.rects) do
    if rect.y == page.meter_y - page.segment_height and rect.w == page.segment_width and rect.filled then
      segments = segments + 1
      local index = (rect.x - page.meter_x) / (page.segment_width + page.segment_gap) + 1
      if rect.level == page.meter_on_level then lit = lit + 1 end
      if rect.level == page.meter_peak_level then peak = index end
    end
  end
  return lit, peak, segments
end

test("E2 picks a slot and leaves the selected voice", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local cursor = local_value("buffer_page")
  assert_equal(cursor.slot, 1, "the slot cursor starts on slot 1")
  assert_equal(cursor.field, 1, "the field cursor starts on the source")
  enc(2, 2)
  assert_equal(cursor.slot, 3, "E2 moves the slot cursor")
  assert_equal(local_value("selected_voice"), 1, "and leaves the selected voice")
  enc(2, 20); assert_equal(cursor.slot, 8, "it stops at slot 8")
  enc(2, -20); assert_equal(cursor.slot, 1, "and at slot 1")
  -- the cursor stays where it was across pages
  enc(2, 4); show_page("MAIN"); enc(2, 2); show_page("BUFFER")
  assert_equal(cursor.slot, 5, "the slot cursor stays across a page change")
  assert_equal(local_value("selected_voice"), 3, "MAIN's E2 still picks the voice BUFFER shows")
  redraw()
  assert_equal(field_rows(context)[1].label, "v3", "the first field names the selected voice")
end)

test("ALT+E2 moves the field cursor and E3 edits that field", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local cursor = local_value("buffer_page")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(4)
  -- field 1: the selected voice's source
  enc(3, 2); assert_equal(params:get("v4_source"), 3, "E3 on field 1 steps v<sel>_source")
  assert_equal(cursor.slot, 1, "E3 leaves the slot cursor")
  redraw()
  local source, record_source = field_named(context, "v4"), field_named(context, "rec")
  assert_equal(source.value, "buf 2", "the source field shows the voice's source")
  assert_true(source.cursor, "the cursor marks the source field")
  assert_equal(source.level, 15, "the field under the cursor is bright")
  assert_equal(record_source.level, 4, "the others dim")
  -- ALT+E2 moves the field cursor, not the slot cursor
  with_alt(function() enc(2, 2) end)
  assert_equal(cursor.field, 3, "ALT+E2 moves to field 3")
  assert_equal(cursor.slot, 1, "and leaves the slot cursor")
  -- field 3: record_duration
  local duration = params:get("record_duration")
  enc(3, 2); assert_true(params:get("record_duration") > duration, "E3 on field 3 sets the duration")
  redraw()
  assert_true(field_named(context, "dur").cursor and not field_named(context, "v4").cursor, "the cursor marks the duration")
  assert_equal(field_named(context, "dur").value, string.format("%.1fs", params:get("record_duration")))
  -- field 4: record_level
  with_alt(function() enc(2, 1) end)
  assert_equal(cursor.field, 4)
  params:set("record_level", 1)
  enc(3, -10); assert_near(params:get("record_level"), 0.8, 1e-6, "E3 on field 4 sets the record level")
  -- ALT+E3 is fine adjustment: a tenth as far
  with_alt(function() enc(3, 10) end)
  assert_near(params:get("record_level"), 0.82, 1e-6, "ALT+E3 moves a tenth as far")
  redraw()
  assert_equal(field_named(context, "lvl").value, string.format("%.2f", params:get("record_level")))
  with_alt(function() enc(2, 20) end)
  assert_equal(cursor.field, 11, "the field cursor stops at field 11")
  with_alt(function() enc(2, -20) end)
  assert_equal(cursor.field, 1, "and at field 1")
  assert_equal(params:get("v4_source"), 3, "the source was left alone meanwhile")
end)

test("K3 records into the slot under the cursor whatever the voices use", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local buffers = local_value("buffers")
  for voice = 1, 7 do assert_equal(params:get("v" .. voice .. "_source"), 1, "voice " .. voice .. " on its synth") end
  enc(2, 2)
  context.clear_engine_calls()
  tap(3)
  assert_true(buffers[3].recording, "K3 records into slot 3")
  assert_equal(context.calls_named("recordBuffer")[1].args[1], 2, "engine slot 2")
  tap(3)
  assert_equal(#context.calls_named("stopRecord"), 1, "K3 again stops early")
  -- a voice reading another slot changes nothing
  params:set("v1_source", 6)  -- buf 5
  context.polls.fire("bufferState", 2005)
  enc(2, 3); context.clear_engine_calls(); tap(3)
  assert_equal(context.calls_named("recordBuffer")[1].args[1], 5, "slot 6, the cursor's, not the voice's 5")
  -- the arc's button records or stops the cursor slot, as K3 does
  local arc_device = context.arc.plug(1)
  assert_true(arc_device ~= nil)
  context.clear_engine_calls()
  context.arc.push(1, 1, 1)
  assert_equal(#context.calls_named("stopRecord"), 1, "the arc button stops the cursor slot's recording")
  assert_equal(context.calls_named("stopRecord")[1].args[1], 5)
end)

test("K2 released loads into the cursor slot", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  enc(2, 3)  -- slot 4; every voice still on its synth
  context.clear_engine_calls(); context.fileselect.last = nil
  key(2, 1)
  assert_equal(context.fileselect.last, nil, "K2's press opens nothing")
  key(2, 0)
  assert_true(context.fileselect.last ~= nil, "K2's release opens the file browser")
  assert_equal(context.fileselect.last.folder, _path.audio, "in the audio folder")
  context.fileselect.last.callback("/tmp/b.wav")
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "the choice loads")
  assert_equal(loads[1].args[1], 3, "into slot 4 (engine slot 3)")
  assert_equal(params:get("buf4_file"), "/tmp/b.wav")
  assert_equal(local_value("S").lib.files.last_folder, "/tmp/", "the chosen file's folder is the next random folder")
  -- a canceled choice loads nothing
  tap(2); context.clear_engine_calls()
  context.fileselect.last.callback("cancel")
  assert_equal(#context.calls_named("loadBuffer"), 0, "cancel loads nothing")
  -- K3 while K2 is held records and does not stop K2's release opening the browser
  context.fileselect.last = nil
  key(2, 1); tap(3); key(2, 0)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 with K2 held records")
  assert_equal(#context.calls_named("saveBuffer"), 0, "and saves nothing (ALT+K3 saves)")
  assert_true(context.fileselect.last ~= nil, "K2's release still opens the browser")
  context.fileselect.close()
end)

test("ALT+K2 clear never opens the file browser", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local buffers = local_value("buffers")
  enc(2, 1)   -- slot 2
  load_buffer(2, "/tmp/keep.wav"); load_buffer(1, "/tmp/other.wav")
  context.polls.fire("bufferState", 1004); context.polls.fire("bufferState", 4)
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K1 down, K2 down, K1 up, K2 up
  key(1, 1); key(2, 1); key(1, 0); key(2, 0)
  local clears = context.calls_named("clearBuffer")
  assert_equal(#clears, 1, "ALT+K2 clears")
  assert_equal(clears[1].args[1], 1, "the cursor slot (engine slot 1)")
  assert_equal(buffers[2].name, "empty", "slot 2 is empty")
  assert_true(buffers[1].loaded, "slot 1 is left alone")
  assert_equal(context.fileselect.last, nil, "the ALT press's release opened no file browser")
  assert_true(not local_value("BUFFER_PAGE").file_selector_open, "and the page still shows")
  -- K2 down, K1 up and down meanwhile: still one clear, no browser
  key(1, 1); key(2, 1); key(2, 0); key(1, 0)
  assert_equal(#context.calls_named("clearBuffer"), 2, "a second ALT+K2 clears again")
  assert_equal(context.fileselect.last, nil, "and opens nothing")
  -- a plain K2 still opens it on release
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the browser")
  context.fileselect.close()
  assert_equal(#context.calls_named("clearBuffer"), 2, "and clears nothing")
end)

test("ALT+K3 saves the cursor slot with the busy, saving, saved and empty flashes", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local buffers = local_value("buffers")
  enc(2, 2)   -- slot 3; no voice reads it
  load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 2004)  -- the engine reports buffer 3's audio
  context.clear_engine_calls(); context.fileselect.last = nil
  context.set_time(100)
  with_alt(function() tap(3) end); next_frame(context)
  local saves = context.calls_named("saveBuffer")
  assert_equal(#saves, 1, "ALT+K3 saves")
  assert_equal(saves[1].args[1], 2, "the cursor slot (engine slot 2)")
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not record")
  assert_equal(hint_text(context), "saving buf 3", "the hint row says the save is under way")
  assert_screen_layout(context, "BUFFER with the saving flash")
  assert_equal(#page_dots(context), 8, "the hint flash leaves the header alone")
  -- the engine reports the file written (bufferSaveResult: (save 1 * 2 + ok 0) * 8 + slot index 2)
  context.set_time(100.2)
  context.polls.fire("bufferSaveResult", (1 * 2 + 0) * 8 + 2); next_frame(context)
  assert_equal(hint_text(context), "saved buf 3", "the hint row confirms the save once the engine reports it")
  assert_screen_layout(context, "BUFFER with the saved flash")
  context.set_time(101.6); redraw()
  assert_equal(hint_text(context), "saved buf 3", "still shown before 1.5 s")
  context.set_time(101.7); redraw()
  assert_equal(hint_text(context), "K2:ld/rnd K3:rec", "the normal hint after 1.5 s")
  -- an empty slot: nothing saved, the hint says so
  enc(2, 1)   -- slot 4, empty
  context.clear_engine_calls()
  with_alt(function() tap(3) end); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "an empty slot is not saved")
  assert_equal(hint_text(context), "buf 4 empty", "the hint says the slot is empty")
  assert_screen_layout(context, "BUFFER with the empty flash")
  -- a recording slot is busy: nothing saved, the recording goes on
  tap(3); assert_true(buffers[4].recording, "K3 records into slot 4")
  context.clear_engine_calls()
  with_alt(function() tap(3) end); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while recording")
  assert_equal(#context.calls_named("stopRecord"), 0, "ALT+K3 does not stop the recording")
  assert_equal(hint_text(context), "buf 4 busy", "the hint says the slot is busy")
  assert_screen_layout(context, "BUFFER with the busy flash while recording")
  -- stopped early: the take waits for the engine (finishing), still busy
  tap(3); assert_true(buffers[4].finishing, "the stopped take is finishing")
  context.clear_engine_calls()
  with_alt(function() tap(3) end); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while finishing")
  assert_equal(hint_text(context), "buf 4 busy", "still busy while finishing")
  -- once the engine reports the take, ALT+K3 saves it
  context.polls.fire("bufferState", 3005)
  assert_true(not buffers[4].finishing, "the take settled")
  with_alt(function() tap(3) end); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "the settled take saves")
  assert_equal(hint_text(context), "saving buf 4")
  context.polls.fire("bufferSaveResult", (1 * 2 + 1) * 8 + 3); next_frame(context)
  assert_equal(hint_text(context), "buf 4 save failed", "a save the engine could not write says so")
  -- K2 held, then K3: records, never saves (the old K2+K3 gesture is gone)
  context.clear_engine_calls()
  key(2, 1); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K2+K3 saves nothing")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  key(2, 0); context.fileselect.close()
end)

test("slots sit 7 px apart, three at a time, with a scroll marker", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local page = local_value("BUFFER_PAGE")
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 1016)
  load_buffer(3, "/tmp/x.wav"); context.polls.fire("bufferState", 2002.5)
  params:set("v2_source", 4); params:set("v6_source", 4)   -- voices 2 and 6 read slot 3
  params:set("v1_source", 3)                               -- voice 1 reads slot 2
  redraw()
  local function shown_slots()
    local rows, slots = slot_rows(context), {}
    for slot = 1, 8 do if rows[slot] then table.insert(slots, slot) end end
    return slots, rows
  end
  local slots, rows = shown_slots()
  assert_equal(table.concat(slots, " "), "1 2 3", "three slots show")
  assert_equal(rows[1], 37, "the first row at y 37"); assert_equal(rows[2], 44); assert_equal(rows[3], 51)
  assert_true(rows[3] < HINT_ROW_Y - TEXT_HEIGHT + 1, "the last row above the hint row")
  local function marker()
    for _, line in ipairs(context.screen.lines) do
      if line.x1 == 127 and line.x2 == 127 then return line end
    end
  end
  local top_marker = marker()
  assert_true(top_marker ~= nil, "a scroll marker at x 127")
  -- the rows' contents: empty slots show "-" and no seconds
  assert_equal(slot_row_text(context, rows[1]), "1 -", "an empty slot shows -")
  assert_equal(slot_row_text(context, rows[2]), "2 drone 16.0s", "a loaded slot: name and seconds")
  assert_true(not h.screen_shows(context, "0.0s"), "no 0.0s anywhere")
  -- the cursor row is bright and lists the voices reading it
  enc(2, 2); redraw()
  slots, rows = shown_slots()
  assert_equal(table.concat(slots, " "), "2 3 4", "one row above the cursor stays in view")
  -- under the layout test's width estimate the name keeps its minimum width, so
  -- the voices shorten to "v2+" (the full list shows with a narrower font, below)
  assert_equal(slot_row_text(context, rows[3]), "3 x v2+ 2.5s", "the cursor row shows its voices, shortened")
  for _, entry in ipairs(texts_on_row(context, rows[3])) do
    if entry.x >= page.slot_x then assert_equal(entry.level, 15, "the cursor row is bright") end
  end
  for _, entry in ipairs(texts_on_row(context, rows[4])) do
    if entry.x >= page.slot_x then assert_true(entry.level < 15, "other rows are dimmer") end
  end
  assert_screen_layout(context, "BUFFER cursor on slot 3")
  -- the end of the list
  enc(2, 5); redraw()
  slots = shown_slots()
  assert_equal(table.concat(slots, " "), "6 7 8", "slot 8 shows at the bottom")
  local bottom_marker = marker()
  assert_true(bottom_marker.y1 > top_marker.y1, "the marker moves down")
  -- a recording slot shows REC
  record_buffer(8); redraw()
  slots, rows = shown_slots()
  assert_equal(slot_row_text(context, rows[8]), "8 - REC", "REC while recording")
  -- every voice on the cursor slot: the voices are cut to fit, the row stays inside its column
  for voice = 1, 7 do params:set("v" .. voice .. "_source", 9) end   -- buf 8
  redraw()
  assert_true(slot_row_text(context, rows[8]):find("v1", 1, true), "the first voices show")
  assert_screen_layout(context, "BUFFER with every voice on the cursor slot")
end)

test("the input meter shows the louder channel with a 1 s peak hold", function()
  local context = load_strata(); finish_startup(context)
  local meter = local_value("S").lib.pages_buffer
  local INPUT_METER = meter.INPUT_METER
  assert_equal(INPUT_METER.poll_seconds, 0.05); assert_equal(INPUT_METER.segments, 8)
  assert_equal(INPUT_METER.floor_db, -48); assert_equal(INPUT_METER.db_per_segment, 6)
  assert_equal(INPUT_METER.peak_hold_seconds, 1)
  assert_equal(meter.input_meter_segments(1), 8, "0 dB lights every segment")
  assert_equal(meter.input_meter_segments(0.5), 7, "-6 dB: seven")
  assert_equal(meter.input_meter_segments(0.001), 0, "-60 dB: none")
  assert_equal(meter.input_meter_segments(0), 0, "silence: none")
  assert_equal(meter.input_meter_segments(-1), 0, "a negative value: none")
  assert_equal(meter.input_meter_segments(0 / 0), 0, "NaN: none")
  assert_equal(meter.input_meter_segments(4), 8, "above 0 dB: all eight")
  local left, right = context.polls.polls.amp_in_l, context.polls.polls.amp_in_r
  assert_true(not left.running and not right.running, "the input polls wait for BUFFER")
  show_page("BUFFER")
  assert_true(left.running and right.running, "BUFFER starts amp_in_l and amp_in_r")
  assert_near(left.time, 0.05, 1e-9, "every 0.05 s"); assert_near(right.time, 0.05, 1e-9)
  redraw()
  local lit, peak, segments = meter_state(context)
  assert_equal(segments, 8, "eight segments"); assert_equal(lit, 0, "silent at first"); assert_equal(peak, nil)
  context.polls.fire("amp_in_l", 0.5); context.polls.fire("amp_in_r", 0.1)
  next_frame(context)
  lit, peak = meter_state(context)
  assert_equal(lit, 7, "the louder channel: 7 segments")
  assert_equal(peak, nil, "no peak above the level")
  assert_screen_layout(context, "BUFFER with the meter lit")
  context.clock.run_for(0.5)
  context.polls.fire("amp_in_l", 0); context.polls.fire("amp_in_r", 0)
  next_frame(context)
  lit, peak = meter_state(context)
  assert_equal(lit, 0, "the level falls at once")
  assert_equal(peak, 7, "the peak segment is held")
  context.clock.run_for(1.01); redraw()
  lit, peak = meter_state(context)
  assert_equal(peak, nil, "the peak is gone after 1 s")
  -- a louder right channel
  context.polls.fire("amp_in_r", 1); next_frame(context)
  assert_equal((meter_state(context)), 8, "the right channel at 0 dB lights all eight")
end)

test("the input polls stop when BUFFER is left and in cleanup", function()
  local context = load_strata(); finish_startup(context)
  local left, right = context.polls.polls.amp_in_l, context.polls.polls.amp_in_r
  show_page("BUFFER")
  assert_true(left.running and right.running, "running on BUFFER")
  context.polls.fire("amp_in_l", 1); next_frame(context)
  assert_equal((meter_state(context)), 8)
  show_page("SCENES")
  assert_true(not left.running and not right.running, "stopped when BUFFER is left")
  assert_equal(left.callback, nil, "a late value after leave reaches no callback")
  assert_equal(right.callback, nil)
  show_page("BUFFER")
  assert_true(left.running and right.running, "running again on BUFFER")
  redraw()
  local lit, peak = meter_state(context)
  assert_equal(lit, 0, "a new visit starts silent")
  assert_equal(peak, nil, "with no held peak")
  cleanup()
  assert_true(not left.running and not right.running, "cleanup stops them")
  -- cleanup on another page (polls never started) is fine
  context = load_strata(); finish_startup(context)
  local ok, problem = pcall(cleanup)
  assert_true(ok, tostring(problem))
  -- a norns without the input polls: BUFFER still draws
  context = load_strata(); finish_startup(context)
  context.polls.polls.amp_in_l, context.polls.polls.amp_in_r = nil, nil
  show_page("BUFFER")
  assert_screen_layout(context, "BUFFER with no input polls")
  show_page("MAIN"); cleanup()
end)

test("BUFFER hints", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  enc(2, 2)
  redraw(); assert_equal(hint_text(context), "K2:ld/rnd K3:rec", "a slot that is not recording")
  record_buffer(3); redraw()
  assert_equal(hint_text(context), "K2:ld/rnd K3:stop", "the cursor slot records")
  enc(2, 1); redraw()
  assert_equal(hint_text(context), "K2:ld/rnd K3:rec", "another slot's recording is not the cursor's")
  enc(2, -1)
  record_buffer(3); redraw()
  assert_equal(hint_text(context), "K2:ld/rnd K3:...", "the take waits for the engine")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:clr/fill K3:sv/trim", "with ALT")
  assert_screen_layout(context, "BUFFER with ALT")
  key(1, 0); redraw()
  assert_equal(hint_text(context), "K2:ld/rnd K3:...")
  -- the same whatever the selected voice's source
  for _, source in ipairs({ 1, 4, 10 }) do
    params:set("v1_source", source); context.polls.fire("bufferState", 2003); redraw()
    assert_equal(hint_text(context), "K2:ld/rnd K3:rec", "source " .. source)
  end
end)

test("the BUFFER page caches each slot's cut name (M3)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local page = local_value("BUFFER_PAGE")
  local measured = 0
  local text_extents = screen.text_extents
  screen.text_extents = function(text) measured = measured + 1; return text_extents(text) end
  -- the loads redraw the page on the next frame (and measure the new names)
  for slot = 1, 8 do load_buffer(slot, "/tmp/a very long sample name number " .. slot .. ".wav") end
  next_frame(context)
  assert_true(measured > 0, "a new name is measured")
  measured = 0
  redraw(); redraw()
  assert_equal(measured, 0, "later draws reuse the cut names")
  enc(2, 1); redraw(); enc(2, -1)
  measured = 0
  redraw(); redraw()
  screen.text_extents = text_extents
  assert_equal(measured, 0, "moving the cursor and back measures nothing new")
  local function names()
    local found = {}
    for _, entry in ipairs(context.screen.texts) do if entry.x == page.name_x then found[entry.y] = entry.text end end
    return found
  end
  local first_y = page.row_first_y
  assert_true(names()[first_y] ~= nil and #names()[first_y] < 20, "the cached name is the cut one")
  load_buffer(1, "/tmp/b.wav"); redraw()
  assert_equal(names()[first_y], "b", "a new name is cut and shown")
  clear_buffer(1); redraw()
  assert_equal(names()[first_y], "-", "a cleared slot shows -")
end)

test("BUFFER K2's release forgets every held key as the file selector opens", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4)
  local held_at_enter
  local stub_enter = context.fileselect.enter
  context.fileselect.enter = function(...)
    held_at_enter = {}
    for n, page in pairs(local_value("key_press_page")) do held_at_enter[n] = page end
    return stub_enter(...)
  end
  -- K3 goes down (it records), then K2 is pressed and released while K3 is
  -- still held: the selector opens and takes K3's release
  key(3, 1); key(2, 1); key(2, 0)
  assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  assert_true(held_at_enter ~= nil and next(held_at_enter) == nil, "no key is held when the selector opens")
  assert_equal(next(local_value("key_press_page")), nil, "and none afterward")
end)

test("BUFFER K2 loads a file with no fileselect global: the script requires it (issue #10)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  assert_equal(rawget(_G, "fileselect"), nil, "norns has no fileselect global")
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  tap(2); assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  context.fileselect.close("/tmp/picked.wav")
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "the chosen file loads")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], "/tmp/picked.wav")
end)

test("Strata's page never draws over the open file selector; redraws draw the selector (issue #10)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local draws = 0  -- Strata's page draws (the stub's fileselect.redraw draws nothing)
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  local selector = context.fileselect
  -- opening it on K2's release: fs.enter's redraw() (from norns.menu.init)
  -- and the frame after key() draw the selector, not the page
  key(2, 1); next_frame(context); draws = 0
  key(2, 0); assert_true(selector.last ~= nil, "K2's release opens the selector")
  next_frame(context)
  assert_equal(draws, 0, "the page does not draw over the selector as it opens")
  assert_equal(selector.redraws, 3, "menu.init's redraw, fs.enter's own and the next frame draw the selector")
  -- the norns menu opened and closed over it (K1 twice): set_mode(false)
  -- clears the screen and calls redraw(), which must show the selector again
  selector.redraws = 0
  _menu.set_mode(true); _menu.set_mode(false); redraw()
  assert_equal(selector.redraws, 1, "norns' redraw() as the menu closes draws the selector")
  assert_equal(draws, 0, "and not Strata's page")
  -- Strata's own redraws (a buffer report, page turns, a load) while it is
  -- open: the frame clock's redraw() draws the selector
  selector.redraws = 0
  context.polls.fire("bufferState", 3005)
  enc(1, -1); enc(1, 1)
  load_buffer(5, "/tmp/other.wav")
  next_frame(context)
  assert_equal(draws, 0, "the page does not draw over the selector while it is open")
  assert_true(selector.redraws > 0, "they draw the selector instead")
  -- canceled: fs.exit's redraw() comes before the callback, which asks
  -- for one redraw
  context.clear_engine_calls()
  context.fileselect.close()
  assert_equal(draws, 0, "the page waits for the next frame")
  next_frame(context)
  assert_equal(draws, 1, "a cancel redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 0, "a cancel loads nothing")
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  redraw(); assert_equal(draws, 2, "the script draws again after a cancel")
  -- a chosen file: loads it, then one redraw. K2's tap opens the selector
  -- before the next frame, which then draws the selector, not the page
  tap(2); next_frame(context); assert_equal(draws, 2, "the page does not draw as the selector opens again")
  draws = 0
  context.fileselect.close("/tmp/chosen.wav")
  next_frame(context)
  assert_equal(draws, 1, "a chosen file redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and loads")
  redraw(); assert_equal(draws, 2, "the script draws again after a choice")
  screen.update = update
end)

test("a file selector that fails to open leaves the BUFFER page drawing (#49)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local stub_enter = context.fileselect.enter
  local script_key, script_enc = key, enc
  -- fails after it has routed its own handlers to play mode, as fs.enter
  -- would if its redraw raised: globals swapped, then norns.menu.init()
  context.fileselect.enter = function()
    key, enc = function() end, function() end
    norns.menu.init()
    error("no audio folder")
  end
  key(2, 1)
  local released, release_error = pcall(key, 2, 0)
  context.fileselect.enter = stub_enter
  assert_true(not released, "K2's release raises the selector's error")
  assert_true(tostring(release_error):find("no audio folder", 1, true), "the same error: " .. tostring(release_error))
  assert_equal(_menu.key, script_key, "play mode routes the keys to Strata again")
  assert_equal(norns.encoders.callback, script_enc, "and the encoders")
  assert_equal(key, script_key, "the key global is Strata's")
  assert_equal(enc, script_enc, "and the enc global")
  assert_equal(local_value("BUFFER_PAGE").file_selector_open, false, "the selector state is cleared")
  local draws = 0
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  next_frame(context)
  screen.update = update
  assert_equal(draws, 1, "the next frame draws the page, not a selector that never opened")
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 opens the selector afterward")
  context.fileselect.close("/tmp/after.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and its choice loads")
end)

test("a menu file selector opened over BUFFER K2's gives Strata its keys and page back as the menu closes (#49)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local page = local_value("BUFFER_PAGE")
  local selector = context.fileselect
  local script_key, script_enc = key, enc
  -- norns' fs.enter, from play mode, puts its own key and enc handlers in
  -- the globals before norns.menu.init() routes them (the stub does not):
  -- only fs.exit for this selector restores them
  local selector_key, selector_enc = function() end, function() end
  local function open_strata_selector()
    tap(2); assert_true(page.file_selector_open, "K2 opens the selector")
    key, enc = selector_key, selector_enc
    norns.menu.init()
    assert_equal(_menu.key, selector_key, "the selector has the keys")
  end
  local function assert_strata_routed(where)
    assert_equal(page.file_selector_open, false, where .. ": the superseded selector state is cleared")
    assert_equal(_menu.key, script_key, where .. ": play mode routes the keys to Strata")
    assert_equal(norns.encoders.callback, script_enc, where .. ": and the encoders")
    assert_equal(key, script_key, where .. ": the key global is Strata's")
    assert_equal(enc, script_enc, where .. ": and the enc global")
  end
  open_strata_selector()
  -- K1 opens and closes the menu over it: the selector is still Strata's
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(page.file_selector_open, "the menu alone leaves the selector open")
  assert_equal(_menu.key, selector_key, "and its keys with it")
  -- K1, PARAMS, a file param: norns has one selector, now the menu's (Strata's
  -- callback is gone); fs.exit gives the menu its handlers back, not Strata's
  _menu.set_mode(true)
  local picked
  selector.enter(_path.audio, function(path) picked = path end)
  selector.close("/tmp/param.wav")
  assert_equal(picked, "/tmp/param.wav", "the PARAMS selector's choice")
  _menu.set_mode(false)  -- K1 back to play mode
  assert_strata_routed("a chosen PARAMS file")
  local draws, selector_redraws = 0, selector.redraws
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  redraw()
  screen.update = update
  assert_equal(draws, 1, "redraw() draws the page again")
  assert_equal(selector.redraws, selector_redraws, "not the file list")
  -- the PARAMS selector canceled (K2 in it) instead of a choice
  open_strata_selector()
  _menu.set_mode(true)
  selector.enter(_path.audio, function(path) picked = path end)
  selector.close()
  assert_equal(picked, "cancel", "the PARAMS selector was canceled")
  _menu.set_mode(false)
  assert_strata_routed("a canceled PARAMS selector")
  -- the menu closed while the PARAMS selector is still open
  open_strata_selector()
  _menu.set_mode(true)
  selector.enter(_path.audio, function() end)
  _menu.set_mode(false)
  assert_strata_routed("a PARAMS selector left open")
  -- Strata's own selector still works
  context.clear_engine_calls()
  tap(2); selector.close("/tmp/b.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "K2's selector loads its choice")
  assert_equal(page.file_selector_open, false)
end)

test("the superseded-selector release acts only as the menu closes, and never breaks BUFFER K2 (#49)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local page = local_value("BUFFER_PAGE")
  local selector = context.fileselect
  -- play mode to play mode (norns.menu.init in fs.enter and fs.exit) is
  -- no menu closing: a callback that is not Strata's changes nothing then
  tap(2)
  local strata_callback = selector.callback
  selector.callback = function() end
  norns.menu.init()
  assert_true(page.file_selector_open, "a set_mode(false) from play mode releases nothing")
  selector.callback = strata_callback
  selector.close("/tmp/a.wav")
  assert_equal(page.file_selector_open, false, "the selector's own callback closes it")
  -- a norns whose fileselect keeps no `callback`: no release ever (the
  -- selector state may stay set, as before #49), and K2 still works
  local stub_enter = selector.enter
  selector.enter = function(...)
    stub_enter(...)
    selector.callback = nil
  end
  context.clear_engine_calls()
  tap(2); assert_true(page.file_selector_open, "K2 opens the selector")
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(page.file_selector_open, "no fileselect.callback: the menu closing releases nothing")
  selector.close("/tmp/b.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "the choice loads")
  assert_equal(page.file_selector_open, false, "and the callback closes it")
  selector.enter = stub_enter
  -- an error in the release never stops the menu closing
  tap(2)
  key, enc = function() end, function() end
  _menu.set_mode(true)
  selector.enter(_path.audio, function() end)
  local real_request_redraw = request_redraw
  request_redraw = function() error("release failed") end
  context.printed = {}
  local closed = pcall(_menu.set_mode, false)
  request_redraw = real_request_redraw
  assert_true(closed, "set_mode(false) does not raise")
  assert_equal(norns.menu.status(), false, "the menu closed")
  assert_true(table.concat(context.printed, "\n"):find("release failed", 1, true), "the error is printed")
end)

test("BUFFER page draws its fields, the meter and the slot rows", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local page = local_value("BUFFER_PAGE")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(6); params:set("v6_source", 3)   -- karplus on buf 2
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 1016)
  load_buffer(3, "/tmp/x.wav"); context.polls.fire("bufferState", 2002.5)
  params:set("record_duration", 2)
  redraw()
  assert_equal(field_labels(context), "v6 rec dur lvl", "the first four fields")
  assert_equal(field_named(context, "v6").value, "buf 2"); assert_equal(field_named(context, "dur").value, "2.0s")
  assert_equal(field_named(context, "lvl").value, "1.00"); assert_equal(field_named(context, "rec").value, "in")
  local divider
  for _, line in ipairs(context.screen.lines) do
    if line.x1 == page.divider_x and line.x2 == page.divider_x and line.level == 1 then divider = line end
  end
  assert_true(divider ~= nil, "a divider between the columns")
  for _, entry in ipairs(context.screen.texts) do
    if entry.y > 8 and entry.y < HINT_ROW_Y then
      local left, right = text_span(entry)
      assert_true(right <= page.divider_x - 1 or left >= page.divider_x + 2,
        string.format("'%s' at %d,%d crosses the divider", entry.text, entry.x, entry.y))
    end
  end
  local rows = slot_rows(context)
  local function row_level(slot)
    local level
    for _, entry in ipairs(texts_on_row(context, rows[slot])) do
      if entry.x >= page.slot_x then
        assert_true(level == nil or level == entry.level, "one level per row")
        level = entry.level
      end
    end
    return level
  end
  assert_equal(slot_row_text(context, rows[1]), "1 -"); assert_equal(row_level(1), 15, "the cursor row bright")
  assert_equal(slot_row_text(context, rows[2]), "2 drone 16.0s"); assert_equal(row_level(2), 6, "a loaded slot")
  assert_equal(slot_row_text(context, rows[3]), "3 x 2.5s")
  clear_buffer(3); redraw(); rows = slot_rows(context)
  assert_equal(row_level(3), 2, "an empty slot dim")
  -- the input source: the field says so
  params:set("v6_source", 10); redraw()
  assert_equal(field_named(context, "v6").value, "input")
  params:set("v6_source", 1); redraw()
  assert_equal(field_named(context, "v6").value, "synth")
  local _, _, segments = meter_state(context)
  assert_equal(segments, 8, "the meter's eight segments")
end)

test("BUFFER page layout holds for every voice, source, buffer state and cursor", function()
  local context = load_strata(); finish_startup(context)
  params:set("mutation_enabled", 1); params:set("master_density", 2.0)
  capture_scene(8); recall_scene(8, 0)
  local cursor = local_value("buffer_page")
  local _, set_selected = find_upvalue("selected_voice")
  local long_names = { "WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
    "café_crème_très_longue.wav", "no_extension_but_long" }
  local function set_buffers(state)
    for slot = 1, 8 do
      if state == "empty" then clear_buffer(slot)
      elseif state == "loaded" then
        load_buffer(slot, "/tmp/" .. long_names[(slot - 1) % #long_names + 1])
        context.polls.fire("bufferState", (slot - 1) * 1000 + 16)
      elseif state == "recording" then
        clear_buffer(slot); record_buffer(slot)
      end
    end
  end
  for _, state in ipairs({ "empty", "loaded", "recording" }) do
    set_buffers(state)
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      for _, source in ipairs({ 1, 2, 5, 9, 10 }) do
        params:set("v" .. voice_idx .. "_source", source)
        for _, slot in ipairs({ 1, 4, 8 }) do
          cursor.slot = slot
          for field = 1, 11 do
            cursor.field = field
            show_page("BUFFER")
            assert_screen_layout(context, string.format("BUFFER, %s, voice %d source %d, slot %d field %d",
              state, voice_idx, source, slot, field))
          end
        end
      end
    end
  end
end)

test("BUFFER changes reach the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local grid_device = context.grid.plug(1, 16, 16)
  show_page("BUFFER")
  h.assert_drawn_on_next_frame(context, arc_hardware, "bufferState report", function()
    context.polls.fire("bufferState", 1005)
  end)
  assert_true(h.screen_shows(context, "5.0s"), "BUFFER shows the reported seconds")
  -- slot 3 records (not the cursor's: a recording cursor slot animates the
  -- page, 3.3); no report comes, so the take settles empty
  record_buffer(3)
  h.assert_drawn_on_next_frame(context, arc_hardware, "recording timer end", function()
    h.wake_buffer_clock(context, 3)
  end)
  assert_true(local_value("buffers")[3].finishing and h.screen_shows(context, "REC"), "BUFFER shows the take finishing")
  h.assert_drawn_on_next_frame(context, arc_hardware, "fallback settle", function()
    h.wake_buffer_clock(context, 3)
  end)
  assert_true(not h.screen_shows(context, "REC"), "BUFFER shows the take settled")
  assert_true(grid_device.refresh_count > 0, "the grid still redraws on its own")
end)

test("BUFFER's layout states draw clear of each other", function()
  local context = load_strata(); finish_startup(context)
  local record = local_value("S").registry.pages[local_value("UI_PAGES").index.BUFFER]
  assert_true(type(record.layout_states) == "table" and #record.layout_states > 0, "BUFFER lists layout states")
  local names = {}
  for _, state in ipairs(record.layout_states) do names[state.name] = true end
  for _, name in ipairs({ "slot 1", "slot 8", "field source", "field rec", "field dur", "field lvl", "field fb",
    "field loop", "field thr", "field sync", "field bm", "field start", "field fric", "long names", "every slot recording",
    "saving flash", "saving loop flash", "saved flash", "saved loop flash", "save failed flash", "busy flash", "empty flash",
    "load failed flash", "random file flash", "filled flash", "no files flash", "meter peak",
    "armed", "take recording", "take finishing", "dub recording", "loop recording", "len 16b max",
    "seven heads on one slot", "record head", "a long file's start", "a long file's start (high, 300 s)",
    "eight slots of 4:59 (high, 300 s)", "a recording at 1:05 (high, 300 s)" }) do
    assert_true(names[name], "a layout state " .. name)
  end
end)

test("a K2 or ALT released inside the norns menu is forgotten: K3 records again (fix round 1)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  enc(2, 2); load_buffer(3, "/tmp/take.wav")
  local drift_metro = local_value("drift_metro")
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens the menu: the K2 release goes to the menu
  key(2, 1)
  context.menu.mode = true; drift_metro.event()   -- a 10 Hz tick while the menu is open
  context.menu.mode = false                       -- K1 again: back to the script
  assert_equal(local_value("key_press_page")[2], nil, "the K2 held into the menu is forgotten")
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  assert_equal(context.fileselect.last, nil, "nothing opened the file selector")
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 2002)  -- the engine reports the 2 s take
  -- ALT held into the menu: forgotten, so K3 records rather than saves
  context.clear_engine_calls()
  key(1, 1)
  context.menu.mode = true; drift_metro.event(); context.menu.mode = false
  assert_true(not local_value("alt_held"), "ALT is forgotten")
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save after ALT was released in the menu")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  tap(3); context.polls.fire("bufferState", 2002)
  -- ticks with the menu closed keep a held ALT
  context.clear_engine_calls()
  key(1, 1); drift_metro.event(); tap(3); key(1, 0)
  assert_equal(#context.calls_named("saveBuffer"), 1, "ALT still held across a tick with the menu closed")
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector")
  context.fileselect.close()
  assert_equal(norns.menu.status(), false, "stub norns.menu.status mirrors _menu.mode")
end)

test("opening the norns menu forgets held keys at once; cleanup restores _menu.set_mode", function()
  local stub_set_mode
  local context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  finish_startup(context); show_page("BUFFER")
  assert_true(_menu.set_mode ~= stub_set_mode, "init watches _menu.set_mode")
  enc(2, 2); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 2004)
  context.clear_engine_calls(); context.fileselect.last = nil
  -- ALT and K2 down, then K1 opens and closes the menu between two 10 Hz ticks
  key(1, 1); key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the wrapped set_mode still opens the menu")
  assert_equal(local_value("key_press_page")[2], nil, "the held K2 is forgotten as the menu opens")
  assert_true(not local_value("alt_held"), "and ALT")
  _menu.set_mode(false)
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 2002)  -- the engine reports the 2 s take
  _menu.set_mode(true); _menu.set_mode(false)
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector")
  context.fileselect.close()
  -- closing the menu forgets nothing (only an opening does)
  key(2, 1); _menu.set_mode(false)
  assert_equal(local_value("key_press_page")[2], local_value("UI_PAGES").index.BUFFER, "set_mode(false) keeps a held key")
  key(2, 0); context.fileselect.close()
  -- cleanup gives norns its own set_mode back
  cleanup()
  assert_equal(_menu.set_mode, stub_set_mode, "cleanup restores set_mode")
  -- something that wrapped set_mode after Strata keeps its wrapper; Strata's goes inert
  stub_set_mode = nil
  context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  local strata_set_mode = _menu.set_mode
  local mod_set_mode = function(mode) strata_set_mode(mode) end
  _menu.set_mode = mod_set_mode
  cleanup()
  assert_equal(_menu.set_mode, mod_set_mode, "a later wrapper is left in place")
  show_page("BUFFER"); key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the inert wrapper still passes the call on")
  assert_equal(local_value("key_press_page")[2], local_value("UI_PAGES").index.BUFFER, "and no longer touches the script's keys")
  _menu.set_mode(false)
end)


test("the cursor row lists the voices in full when they fit, and keeps the name's minimum width", function()
  -- a font narrower than the layout estimate (4 px a character), from before the
  -- first draw, so nothing is measured with the estimate
  local context = load_strata(); finish_startup(context)
  local text_extents = screen.text_extents
  screen.text_extents = function(text) return 4 * #tostring(text), 8 end
  local page = local_value("BUFFER_PAGE")
  load_buffer(3, "/tmp/x.wav"); context.polls.fire("bufferState", 2002.5)
  params:set("v2_source", 4); params:set("v6_source", 4)   -- voices 2 and 6 read slot 3
  local_value("buffer_page").slot = 3
  show_page("BUFFER")
  local rows = slot_rows(context)
  assert_equal(slot_row_text(context, rows[3]), "3 x v2 v6 2.5s", "the cursor row shows v2 v6")
  -- a long name with every voice on the slot: the voices shorten, the name keeps its room
  load_buffer(3, "/tmp/a_long_name_for_the_slot.wav"); context.polls.fire("bufferState", 2016)
  for voice = 1, 7 do params:set("v" .. voice .. "_source", 4) end
  redraw()
  local name, voices
  for _, entry in ipairs(texts_on_row(context, rows[3])) do
    if entry.x == page.name_x then name = entry.text end
    if entry.text:match("^v%d") then voices = entry end
  end
  screen.text_extents = text_extents
  assert_true(name ~= nil and 4 * #name >= page.name_min_width - 4, "the name keeps about its minimum width: " .. tostring(name))
  assert_true(voices ~= nil and voices.text:sub(-1) == "+", "the voices are shortened with +: " .. tostring(voices and voices.text))
end)

-- A high tier with buffers of `seconds` for the next load_strata
local function write_high_tier(seconds)
  h.write_performance_active({ tier = "high", buffer_seconds = seconds, max_grains = 128, history_seconds = 60,
    reason = "high: setting" })
end

test("the record duration reaches the tier's buffer length", function()
  write_high_tier(60)
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  to_field(3)   -- the duration field
  for _ = 1, 40 do enc(3, 5) end
  assert_equal(params:get("record_duration"), 60, "E3 takes the duration to the slot length")
  redraw()
  assert_equal(field_named(context, "dur").value, "60.0s", "the field shows it")
  assert_screen_layout(context, "BUFFER with a 60 s duration")
  context.clear_engine_calls()
  tap(3)
  local call = context.calls_named("recordBuffer")[1]
  assert_true(call ~= nil and call.args[1] == 0, "K3 records into the cursor slot")
  assert_near(call.args[2], 60, 1e-9, "for the tier's 60 s")
  -- on standard it stops at 16
  context = load_strata(); finish_startup(context); show_page("BUFFER")
  to_field(3)
  for _ = 1, 40 do enc(3, 5) end
  assert_equal(params:get("record_duration"), 16, "standard stops at 16 s")
end)

test("BUFFER shows 65 s as 1:05 and 16.5 s as today", function()
  write_high_tier(300)
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local cases = { { 65, "1:05" }, { 16.5, "16.5s" }, { 59.9, "59.9s" }, { 60, "1:00" }, { 59.96, "1:00" },
    { 299.4, "4:59" }, { 300, "5:00" }, { 0.5, "0.5s" } }
  for index, case in ipairs(cases) do
    local slot = (index - 1) % 3 + 1   -- the three rows shown with the cursor on slot 1
    load_buffer(slot, "/tmp/x" .. index .. ".wav")
    context.polls.fire("bufferState", (slot - 1) * 1000 + case[1])
    redraw()
    local rows = slot_rows(context)
    assert_equal(slot_row_text(context, rows[slot]), slot .. " x" .. index .. " " .. case[2],
      string.format("%s s shows as %s", case[1], case[2]))
    assert_screen_layout(context, "BUFFER with a slot of " .. case[1] .. " s")
  end
end)


-- The 300 s layout states widen the duration's range on a copy of its
-- spec, never on the spec the param was built with (#157)
test("BUFFER's 300 s layout states leave the duration's own spec alone", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local S = local_value("S")
  local param = params:lookup_param("record_duration")
  local original = param.controlspec
  for _, state in ipairs(S.registry.pages[local_value("UI_PAGES").index.BUFFER].layout_states) do
    if state.name:find("300 s", 1, true) then
      param.controlspec = original
      state.setup(context)
      assert_equal(original.maxval, 16, state.name .. ": the spec the param was built with still ends at 16 s")
      assert_true(param.controlspec ~= original, state.name .. ": the param reads a copy")
      assert_equal(param.controlspec.maxval, 300, state.name .. ": the copy ends at 300 s")
      assert_equal(param.controlspec.step, original.step, state.name .. ": the copy keeps the step")
    end
  end
  assert_true(params:get("record_duration") > 16, "the state's duration is past the standard range")
end)

-- While the engine checks a long file the row shows "..." for its length,
-- never the old one beside the new name (#171)
test("BUFFER shows a long file the engine is checking as loading", function()
  write_high_tier(300)
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  context.audio.files["/tmp/long.wav"] = {2, 48000 * 120, 48000}
  load_buffer(1, "/tmp/old.wav"); context.polls.fire("bufferState", 8)
  redraw()
  local rows = slot_rows(context)
  assert_equal(slot_row_text(context, rows[1]), "1 old 8.0s")
  load_buffer(1, "/tmp/long.wav"); context.polls.fire("bufferState", 8)
  redraw()
  assert_equal(slot_row_text(context, rows[1]), "1 long ...", "the new name, loading")
  assert_screen_layout(context, "BUFFER with a long file checking")
  context.polls.fire("bufferState", 0); context.polls.fire("bufferState", 120)
  redraw()
  assert_equal(slot_row_text(context, rows[1]), "1 long 2:00", "then its own length")
end)

-- 3.3: the record fields, the waveform with its heads and bookmarks, the
-- recording states, the holds (design 3.3 section 8.1)

-- Write slot's peaks file as the engine does (lib/waveforms.lua reads it on
-- a later frame tick), for a slot of `seconds` at 48 kHz
local function write_peaks(slot, values, seconds)
  local folder = local_value("S").lib.scenes.scene_data_dir
  util.make_dir(folder)
  local parts = {}
  for index, value in ipairs(values) do parts[index] = string.format("%.3f", value) end
  local file = assert(io.open(folder .. "buf" .. slot .. ".peaks", "w"))
  file:write(string.format("strata-peaks 1\nslot %d\nframes %d\nrate 48000\ngeneration 1\npeaks %s\n",
    slot, math.floor(seconds * 48000), table.concat(parts, " ")))
  file:close()
end

-- Slot 1 loaded with 12 s whose peaks are all `peak`, read in
local function slot_with_peaks(context, peak)
  local values = {}
  for index = 1, 64 do values[index] = peak end
  load_buffer(1, "/tmp/wave.wav")
  write_peaks(1, values, 12)
  context.polls.fire("bufferState", 12)
  context.clock.run_for(0.2)
end

-- The waveform's columns: vertical lines inside x 60-123, y 11-27 (not a
-- head, which spans all of it), by x
local function waveform_columns(context)
  local columns = {}
  for _, line in ipairs(context.screen.lines) do
    local top, bottom = math.min(line.y1, line.y2), math.max(line.y1, line.y2)
    if line.x1 == line.x2 and line.x1 >= 60 and line.x1 <= 123 and top >= 11 and bottom <= 27
      and not (top == 11 and bottom == 27) then
      columns[line.x1] = line
    end
  end
  return columns
end

-- Start or stop a voice (voice 1 runs after startup)
local function set_running(voice_idx, running)
  if local_value("voices")[voice_idx].active ~= running then toggle_voice(voice_idx) end
end

-- Vertical head lines spanning y 11-27, by x
local function head_lines(context)
  local heads = {}
  for _, line in ipairs(context.screen.lines) do
    if line.x1 == line.x2 and math.min(line.y1, line.y2) == 11 and math.max(line.y1, line.y2) == 27 then
      heads[line.x1] = line
    end
  end
  return heads
end

test("BUFFER's fields scroll four at a time and edit their params", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local cursor = local_value("buffer_page")
  with_alt(function() for _ = 1, 4 do enc(2, 1) end end)
  assert_equal(cursor.field, 5, "the cursor on fb")
  redraw()
  assert_equal(field_labels(context), "lvl fb loop thr", "one row of context above the cursor")
  local rows = field_rows(context)
  for index, y in ipairs({ 16, 24, 32, 40 }) do assert_equal(rows[index].y, y, "row " .. index .. " at y " .. y) end
  assert_true(rows[2].cursor, "the cursor marks fb")
  enc(3, 5); assert_near(params:get("record_feedback"), 5, 1e-9, "E3 sets the record feedback")
  redraw(); assert_equal(field_named(context, "fb").value, "5%")
  with_alt(function() for _ = 1, 6 do enc(2, 1) end end)
  assert_equal(cursor.field, 11, "the cursor on fric")
  redraw()
  assert_equal(field_labels(context), "sync bm start fric", "the last page")
  assert_equal(field_named(context, "fric").value, "100%")
  enc(3, -1); assert_near(params:get("scrub_friction"), 99, 1e-9, "E3 sets the friction")
  assert_screen_layout(context, "BUFFER on fric")
  -- the scroll marker sits on the divider, brighter than it
  local page, marker = local_value("BUFFER_PAGE"), nil
  for _, line in ipairs(context.screen.lines) do
    if line.x1 == page.divider_x and line.x2 == page.divider_x and line.level == 4 then marker = line end
  end
  assert_true(marker ~= nil, "the fields' scroll marker on the divider at level 4")
end)

test("the len field shows beats with sync on and 16b max when capped", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  to_field(3)
  params:set("record_sync", 2); params:set("record_beats", 16)
  redraw()
  assert_equal(field_named(context, "len").value, "16b", "16 beats at 120 BPM fit the slot")
  enc(3, 1); assert_equal(params:get("record_beats"), 17, "E3 sets the beats with sync on")
  params:set("record_beats", 16)
  params:set("clock_tempo", 30); redraw()
  assert_equal(field_named(context, "len").value, "8b max", "16 beats at 30 BPM are 32 s: 8 beats fit")
  assert_screen_layout(context, "BUFFER len capped")
  params:set("record_sync", 1); redraw()
  assert_equal(field_named(context, "dur").value, string.format("%.1fs", params:get("record_duration")),
    "sync off: the duration")
end)

test("the bm field steps 1-4 and recalls the bookmark it lands on", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)   -- voice 1 on slot 1
  to_field(9)
  redraw()
  assert_equal(field_named(context, "bm").value, "1 0.00", "nothing recalled: bookmark 1")
  enc(3, 1)
  redraw()
  assert_equal(field_named(context, "bm").value, "2 0.25")
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-6, "bookmark 2 recalled")
  assert_equal(local_value("S").lib.positions.last_recalled(1), 2)
  enc(3, 3); redraw()
  assert_equal(field_named(context, "bm").value, "4 0.75", "it stops at 4")
  assert_near(params:get("v1_buf_pos"), 0.75, 1e-6)
  assert_equal(field_named(context, "bm").level, 15, "bright under the cursor")
  params:set("v1_source", 1); redraw()
  assert_equal(field_named(context, "bm").level, 4, "a synth voice: dim even under the cursor")
end)

test("the start field shows - for a file that fits and 12.0s for a long one", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local buffers = local_value("buffers")
  context.audio.register("/tmp/ten.wav", { channels = 2, frames = 48000 * 10, rate = 48000 })
  load_buffer(1, "/tmp/ten.wav"); context.polls.fire("bufferState", 10)
  to_field(10)
  redraw()
  assert_equal(field_named(context, "start").value, "-", "a file that fits")
  context.clear_engine_calls()
  enc(3, 5); context.clock.run_for(0.5)
  assert_equal(buffers[1].start, 0, "E3 does nothing")
  assert_equal(#context.calls_named("loadBuffer"), 0)
  context.audio.register("/tmp/sixty.wav", { channels = 2, frames = 48000 * 60, rate = 48000 })
  load_buffer(1, "/tmp/sixty.wav"); context.polls.fire("bufferState", 16)
  context.clear_engine_calls()
  for _ = 1, 120 do enc(3, 1) end
  redraw()
  assert_equal(field_named(context, "start").value, "12.0s", "tenths")
  with_alt(function() for _ = 1, 5 do enc(3, 1) end end)
  redraw()
  assert_equal(field_named(context, "start").value, "12.05s", "ALT+E3: hundredths")
  assert_screen_layout(context, "BUFFER with a long file's start")
  assert_equal(#context.calls_named("loadBuffer"), 0, "no reload while E3 turns")
  context.clock.run_for(0.31)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "one reload 0.3 s after the last detent")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], "/tmp/sixty.wav")
  assert_near(loads[1].args[3], 12.05, 1e-6)
end)

test("K2 released before 0.5 s opens the file selector, after 0.5 s loads a random file", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local S = local_value("S")
  assert_equal(local_value("BUFFER_PAGE").hold_seconds, 0.5)
  local randoms = {}
  S.lib.files.random_into = function(slot) table.insert(randoms, slot); return true end
  enc(2, 2)
  context.fileselect.last = nil
  context.set_time(100); key(2, 1); context.set_time(100.3); key(2, 0)
  assert_true(context.fileselect.last ~= nil, "a short K2 opens the file selector")
  assert_equal(#randoms, 0)
  context.fileselect.close(); context.fileselect.last = nil
  context.set_time(101); key(2, 1); context.set_time(101.6); key(2, 0)
  assert_equal(context.fileselect.last, nil, "a held K2 opens nothing")
  assert_equal(table.concat(randoms, " "), "3", "and loads a random file into the cursor slot")
end)

test("ALT+K2 clears on release before 0.5 s and fills the empty slots after it", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local S = local_value("S")
  local fills = 0
  S.lib.files.fill_empty = function() fills = fills + 1; return 0 end
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 4)
  context.clear_engine_calls()
  context.set_time(100); key(1, 1); key(2, 1)
  assert_equal(#context.calls_named("clearBuffer"), 0, "nothing at the press")
  context.set_time(100.2); key(2, 0); key(1, 0)
  local clears = context.calls_named("clearBuffer")
  assert_equal(#clears, 1, "a short ALT+K2 clears"); assert_equal(clears[1].args[1], 0)
  assert_equal(fills, 0)
  context.clear_engine_calls()
  context.set_time(101); key(1, 1); key(2, 1); context.set_time(101.7); key(2, 0); key(1, 0)
  assert_equal(fills, 1, "a held ALT+K2 fills the empty slots")
  assert_equal(#context.calls_named("clearBuffer"), 0, "and clears nothing")
end)

test("ALT+K3 saves the slot on release before 0.5 s and its loop region after it", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  load_buffer(1, "/tmp/a.wav"); context.polls.fire("bufferState", 4)
  context.clear_engine_calls()
  context.set_time(100); key(1, 1); key(3, 1)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing at the press")
  context.set_time(100.2); key(3, 0); key(1, 0); redraw()
  local saves = context.calls_named("saveBuffer")
  assert_equal(#saves, 1, "a short ALT+K3 saves")
  assert_equal(saves[1].args[1], 0); assert_equal(saves[1].args[3], 0); assert_equal(saves[1].args[4], 1)
  assert_true(not saves[1].args[2]:find("-loop", 1, true), "the whole slot")
  assert_equal(hint_text(context), "saving buf 1")
  context.clear_engine_calls()
  context.set_time(101); key(1, 1); key(3, 1); context.set_time(101.7); key(3, 0); key(1, 0); redraw()
  saves = context.calls_named("saveBuffer")
  assert_equal(#saves, 1, "a held ALT+K3 saves the loop region")
  assert_true(saves[1].args[2]:match("%-buf1%-loop%.wav$") ~= nil, "to a -loop file: " .. saves[1].args[2])
  assert_equal(saves[1].args[3], 0); assert_equal(saves[1].args[4], 1)
  assert_equal(hint_text(context), "saving buf 1 loop")
  context.polls.fire("bufferSaveResult", (2 * 2 + 0) * 8 + 0); next_frame(context)
  assert_equal(hint_text(context), "saved buf 1 loop")
  -- busy while recording, held or not
  record_buffer(1); context.clear_engine_calls()
  context.set_time(110); key(1, 1); key(3, 1); context.set_time(110.7); key(3, 0); key(1, 0); redraw()
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while recording")
  assert_equal(hint_text(context), "buf 1 busy")
end)

test("ALT+K2 keeps its release when K1 comes up first", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local S = local_value("S")
  local fills = 0
  S.lib.files.fill_empty = function() fills = fills + 1; return 0 end
  context.clear_engine_calls(); context.fileselect.last = nil
  context.set_time(100); key(1, 1); key(2, 1); key(1, 0); context.set_time(100.2); key(2, 0)
  assert_equal(#context.calls_named("clearBuffer"), 1, "a short ALT+K2 clears")
  assert_equal(context.calls_named("clearBuffer")[1].args[1], 0)
  assert_equal(context.fileselect.last, nil, "no file selector")
  context.clear_engine_calls()
  context.set_time(101); key(1, 1); key(2, 1); key(1, 0); context.set_time(101.7); key(2, 0)
  assert_equal(fills, 1, "a held ALT+K2 fills")
  assert_equal(#context.calls_named("clearBuffer"), 0)
  assert_equal(context.fileselect.last, nil, "still no file selector")
end)

test("K3 records, stops and cancels while armed; the hint follows", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  redraw(); assert_equal(hint_text(context), "K2:ld/rnd K3:rec")
  params:set("record_threshold", 2)   -- waits for -48 dB: armed
  context.clear_engine_calls(); tap(3)
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  assert_equal(local_value("S").lib.record.state(1).phase, "armed")
  redraw(); assert_equal(hint_text(context), "K2:ld/rnd K3:stop", "stop while armed")
  tap(3)
  assert_equal(#context.calls_named("stopRecord"), 1, "K3 again cancels the armed recording")
  assert_equal(context.calls_named("stopRecord")[1].args[1], 0)
  redraw(); assert_equal(hint_text(context), "K2:ld/rnd K3:...", "while the take finishes")
  context.polls.fire("recordState", (1 * 4 + 3) * 8 + 0)   -- canceled
  redraw(); assert_equal(hint_text(context), "K2:ld/rnd K3:rec")
  params:set("record_threshold", 1)
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:ld/rnd K3:stop", "stop while recording")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:clr/fill K3:sv/trim", "with ALT held")
  key(1, 0)
end)

test("the rec, thr and sync fields show their values", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  for _, case in ipairs({ { 1, "in" }, { 2, "pre" }, { 3, "post" }, { 6, "v3" }, { 10, "v7" } }) do
    params:set("record_source", case[1]); redraw()
    assert_equal(field_named(context, "rec").value, case[2], "record source " .. case[1])
  end
  to_field(7)
  redraw(); assert_equal(field_named(context, "thr").value, "off")
  params:set("record_threshold", 6); redraw()
  assert_equal(field_named(context, "thr").value, "-24dB")
  assert_equal(field_named(context, "sync").value, "off")
  params:set("record_sync", 3); redraw()
  assert_equal(field_named(context, "sync").value, "bar")
  assert_equal(field_named(context, "loop").value, "off")
  params:set("record_loop", 2); redraw()
  assert_equal(field_named(context, "loop").value, "on")
end)

test("the selected voice's bookmarks tick at y 30-31, the last recalled at 15", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local function ticks()
    local found = {}
    for _, rect in ipairs(context.screen.rects) do
      if rect.y == 30 and rect.h == 2 and rect.w == 1 then found[rect.x] = rect.level end
    end
    return found
  end
  params:set("v1_source", 2); redraw()
  local found = ticks()
  for _, x in ipairs({ 60, 76, 92, 108 }) do assert_equal(found[x], 6, "a tick at x " .. x) end
  local S = local_value("S")
  S.lib.positions.recall_bookmark(1, 2); redraw()
  found = ticks()
  assert_equal(found[76], 15, "the last recalled bright"); assert_equal(found[60], 6)
  params:set("v1_source", 3); redraw()
  assert_equal(next(ticks()), nil, "voice 1 on another slot: none")
end)

test("the waveform draws 64 columns with the loop brighter and a flat line when empty", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  slot_with_peaks(context, 0.5)
  params:set("v1_source", 2)
  params:set("v1_loop_start", 0.25); params:set("v1_loop_length", 0.5)
  redraw()
  local columns, count = waveform_columns(context), 0
  for x = 60, 123 do
    local line = columns[x]
    assert_true(line ~= nil, "a column at x " .. x)
    count = count + 1
    assert_equal(math.min(line.y1, line.y2), 15, "half-height 4 above y 19")
    assert_equal(math.max(line.y1, line.y2), 23, "and below it")
    assert_equal(line.level, (x >= 76 and x <= 107) and 8 or 3, "the loop brighter at x " .. x)
  end
  assert_equal(count, 64)
  params:set("v1_source", 1); redraw()
  columns = waveform_columns(context)
  for x = 60, 123 do assert_equal(columns[x].level, 6, "no selected voice on the slot: level 6") end
  enc(2, 1); redraw()   -- slot 2, empty
  local flat
  for _, line in ipairs(context.screen.lines) do
    if line.y1 == 19 and line.y2 == 19 and line.x1 == 60 and line.x2 == 123 then flat = line end
  end
  assert_true(flat ~= nil and flat.level == 1, "an empty slot: a flat line at level 1")
  assert_equal(next(waveform_columns(context)), nil, "and no columns")
end)

test("each running voice on the slot draws its playhead, the selected one at 15", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2); params:set("v3_source", 2)
  params:set("v1_buf_pos", 0.25); params:set("v3_buf_pos", 0.5)
  params:set("v1_grain_spread", 0.25)
  set_running(1, true); set_running(3, true)
  redraw()
  local heads = head_lines(context)
  assert_true(heads[76] ~= nil and heads[76].level == 15, "the selected voice's head at 15")
  assert_true(heads[92] ~= nil and heads[92].level == 8, "another voice's at 8")
  local spread
  for _, line in ipairs(context.screen.lines) do
    if line.y1 == 28 and line.y2 == 28 and line.x1 == 68 and line.x2 == 84 then spread = line end
  end
  assert_true(spread ~= nil and spread.level == 4, "voice 1's spread at y 28, level 4")
  set_running(1, false); set_running(3, false)
  -- the slot recording playably: a dotted record head
  params:set("record_feedback", 50)
  context.set_time(200); record_buffer(1); context.set_time(202)   -- 2 s of 8
  redraw()
  local dots = {}
  for _, rect in ipairs(context.screen.rects) do
    if rect.x == 76 and rect.w == 1 and rect.h == 1 and rect.level == 12 then table.insert(dots, rect.y) end
  end
  table.sort(dots)
  assert_equal(table.concat(dots, " "), "11 13 15 17 19 21 23 25 27", "every other pixel at the record head")
end)

test("BUFFER animates while a voice reads the cursor slot or it records", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local record = local_value("S").registry.pages[local_value("UI_PAGES").index.BUFFER]
  set_running(1, false)
  assert_true(record.animates ~= nil and not record.animates(), "nothing moves")
  params:set("v1_source", 2); set_running(1, true)
  assert_true(record.animates(), "voice 1 runs on the cursor slot")
  set_running(1, false)
  assert_true(not record.animates(), "stopped")
  params:set("v1_source", 1)
  params:set("record_feedback", 50); record_buffer(1)
  assert_true(record.animates(), "the slot records playably")
end)

test("slot rows show ARM, REC, DUB and LOOP", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("record_threshold", 2); record_buffer(1)
  params:set("record_threshold", 1); record_buffer(2)
  params:set("record_feedback", 50); record_buffer(3)
  params:set("record_loop", 2); record_buffer(4)
  local function state_text(slot)
    local rows = slot_rows(context)
    for _, entry in ipairs(texts_on_row(context, rows[slot])) do
      if entry.align == "right" and entry.x == 124 then return entry.text end
    end
  end
  redraw()
  assert_equal(state_text(1), "ARM"); assert_equal(state_text(2), "REC"); assert_equal(state_text(3), "DUB")
  assert_screen_layout(context, "BUFFER with ARM, REC and DUB")
  enc(2, 3); redraw()
  assert_equal(state_text(4), "LOOP")
end)


end

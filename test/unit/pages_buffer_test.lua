-- test/unit/pages_buffer_test.lua
-- The BUFFER page (lib/pages/buffer.lua): its rows, keys, flashes and the
-- file selector
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

test("BUFFER page: E3 cycles source, K3 records into the voice's slot, K2 opens the file selector", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  enc(3, 2); assert_equal(params:get("v1_source"), 3)
  key(3, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 1)
  key(3, 0)
  -- K2 acts on release (a 3.0 review fix), so the K2 press is a press and release
  tap(2); assert_true(context.fileselect.last ~= nil, "fileselect opened")
  assert_equal(context.fileselect.last.folder, _path.audio, "file selector starts in the audio folder")
  context.fileselect.last.callback("/tmp/b.wav"); assert_equal(params:get("buf2_file"), "/tmp/b.wav")
  params:set("v1_source", 1); context.clear_engine_calls(); context.fileselect.last = nil
  tap(3); tap(2)
  assert_equal(#context.calls_named("recordBuffer"), 0, "K3 does nothing for a synth voice")
  assert_equal(context.fileselect.last, nil, "K2 does nothing for a synth voice")
  redraw(); for _, entry in ipairs(context.screen.texts) do local l, r = text_span(entry); assert_true(r <= 128) end
  -- E2 selects the voice (shared with MAIN); a canceled selection loads nothing
  enc(2, 3); assert_equal(local_value("selected_voice"), 4)
  params:set("v4_source", 7); tap(2); context.clear_engine_calls()
  context.fileselect.last.callback("cancel")
  assert_equal(#context.calls_named("loadBuffer"), 0, "cancel loads nothing")
  assert_equal(voice_buffer_slot(4), 6); assert_equal(voice_buffer_slot(1), nil)
  params:set("v1_source", 10); assert_equal(voice_buffer_slot(1), nil, "input has no buffer slot")
end)

test("the BUFFER page caches each slot's cut name (M3)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local measured = 0
  local text_extents = screen.text_extents
  screen.text_extents = function(text) measured = measured + 1; return text_extents(text) end
  -- the loads redraw the page on the next frame (and measure the new names)
  for slot = 1, 8 do load_buffer(slot, "/tmp/a very long sample name number " .. slot .. ".wav") end
  next_frame(context)
  assert_true(measured > 0, "a new name is measured")
  measured = 0
  redraw(); redraw()
  screen.text_extents = text_extents
  assert_equal(measured, 0, "later draws reuse the cut names")
  local names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_true(names[14] ~= nil and #names[14] < 20, "the cached name is the cut one")
  load_buffer(1, "/tmp/b.wav"); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "b", "a new name is cut and shown")
  clear_buffer(1); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "empty", "a cleared slot shows empty")
end)

test("BUFFER page: K2+K3 saves, K2 release then does not open the selector", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- the engine reports buffer 3's audio
  context.clear_engine_calls(); context.fileselect.last = nil
  key(2, 1); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K3 with K2 held saves")
  assert_equal(context.calls_named("saveBuffer")[1].args[1], 2, "the voice's buffer")
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not record")
  tap(3); assert_equal(#context.calls_named("saveBuffer"), 2, "each K3 while K2 is held saves")
  key(2, 0); assert_equal(context.fileselect.last, nil, "K2 release after a save opens nothing")
  -- the next plain K2 opens the selector again, and a plain K3 records
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 alone opens the selector")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 alone records")
  tap(3); assert_equal(#context.calls_named("stopRecord"), 1, "K3 again stops early")
  context.polls.fire("bufferState", 205)  -- the engine reports the stopped take
  -- a K2 held across a page change is released elsewhere: no selector, and
  -- back on BUFFER K3 records
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); show_page("MAIN"); key(2, 0); show_page("BUFFER")
  assert_equal(context.fileselect.last, nil, "K2 released on another page opens nothing")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records once K2 is up")
  assert_equal(#context.calls_named("saveBuffer"), 0)
end)

-- The save confirmation's 1.5 s flash: "the BUFFER hint flash still shows on
-- the hint row for 1.5 s" below

test("BUFFER page K2+K3 on a recording or finishing buffer flashes busy and saves nothing", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4)
  local buffers = local_value("buffers")
  tap(3); assert_true(buffers[3].recording, "K3 records into buffer 3")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while recording")
  assert_equal(#context.calls_named("stopRecord"), 0, "K2+K3 does not stop the recording")
  assert_equal(hint_text(context), "buf 3 busy", "the hint says the buffer is busy")
  assert_screen_layout(context, "BUFFER with the busy flash while recording")
  -- stopped early: the take waits for the engine (finishing)
  tap(3); assert_true(buffers[3].finishing, "the stopped take is finishing")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while finishing")
  assert_equal(hint_text(context), "buf 3 busy", "still busy while finishing")
  assert_screen_layout(context, "BUFFER with the busy flash while finishing")
  -- once the engine reports the take, K2+K3 saves it
  context.polls.fire("bufferState", 205)
  assert_true(not buffers[3].finishing, "the take settled")
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "the settled take saves")
  assert_equal(hint_text(context), "saved buf 3")
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
  assert_equal(local_value("buffer_saved_during_k2"), false, "the K2-save flag is clear")
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
  context.polls.fire("bufferState", 305)
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

test("BUFFER page draws the voice, its source and eight buffer rows", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(6); params:set("v6_source", 3)   -- karplus on buf 2
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 116)
  load_buffer(5, "/tmp/x.wav"); context.polls.fire("bufferState", 402.5)
  params:set("record_duration", 2); record_buffer(7)
  redraw()
  local left_name, left_source
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 18 then left_name = entry.text end
    if entry.x == 0 and entry.y == 26 then left_source = entry.text end
  end
  assert_equal(left_name, "KARPLUS"); assert_equal(left_source, "src: buf 2")
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x >= 65 and entry.y > 8 then   -- below the header (its REC: slot 7 records)
      rows[entry.y] = rows[entry.y] or {}
      table.insert(rows[entry.y], entry)
    end
  end
  local row_ys = {}
  for y in pairs(rows) do table.insert(row_ys, y) end
  table.sort(row_ys)
  assert_equal(#row_ys, 8, "eight buffer rows")
  assert_true(row_ys[1] > 8 and row_ys[8] < HINT_ROW_Y - TEXT_HEIGHT + 1, "rows between header and hints")
  local function row_text(slot)
    local parts = {}
    for _, entry in ipairs(texts_on_row(context, row_ys[slot])) do
      if entry.x >= 65 then table.insert(parts, entry.text) end
    end
    return table.concat(parts, " ")
  end
  local function row_level(slot)
    local level
    for _, entry in ipairs(rows[row_ys[slot]]) do
      assert_true(level == nil or level == entry.level, "one level per row")
      level = entry.level
    end
    return level
  end
  assert_equal(row_text(1), "1 empty 0.0s"); assert_equal(row_level(1), 2, "empty buffer dim")
  assert_equal(row_text(2), "2 drone 16.0s"); assert_equal(row_level(2), 15, "the voice's buffer bright")
  assert_equal(row_text(5), "5 x 2.5s"); assert_equal(row_level(5), 8, "loaded buffer")
  assert_equal(row_text(7), "7 empty REC", "REC while recording"); assert_equal(row_level(7), 8)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save")
  -- the voice's buffer recording: the hint says K3 stops
  record_buffer(2); redraw()
  assert_equal(hint_text(context), "K2:load K3:stop K2+3:save")
  -- not a buffer: the hint says K2 and K3 do nothing
  params:set("v6_source", 1); redraw()
  assert_equal(hint_text(context), "K2:- K3:- E3:source")
  params:set("v6_source", 10); redraw()
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 26 then assert_equal(entry.text, "src: input") end
  end
end)

test("BUFFER page layout holds for every voice, source and buffer state", function()
  local context = load_strata(); finish_startup(context)
  params:set("mutation_enabled", 1); params:set("master_density", 2.0)
  capture_scene(8); recall_scene(8, 0)
  local _, set_selected = find_upvalue("selected_voice")
  local long_names = { "WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
    "café_crème_très_longue.wav", "no_extension_but_long" }
  local function set_buffers(state)
    for slot = 1, 8 do
      if state == "empty" then clear_buffer(slot)
      elseif state == "loaded" then
        load_buffer(slot, "/tmp/" .. long_names[(slot - 1) % #long_names + 1])
        context.polls.fire("bufferState", (slot - 1) * 100 + 16)
      elseif state == "recording" then
        clear_buffer(slot); record_buffer(slot)
      end
    end
  end
  for _, state in ipairs({ "empty", "loaded", "recording" }) do
    set_buffers(state)
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      for source = 1, 10 do
        params:set("v" .. voice_idx .. "_source", source)
        show_page("BUFFER")
        assert_screen_layout(context, "BUFFER, " .. state .. ", voice " .. voice_idx .. " source " .. source)
      end
    end
  end
end)

test("the BUFFER hint flash still shows on the hint row for 1.5 s", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local S = local_value("S")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- buffer 3 holds 4 s
  context.set_time(100)
  key(2, 1); tap(3); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 saves")
  assert_equal(hint_text(context), "saved buf 3", "the hint row confirms the save")
  assert_screen_layout(context, "BUFFER with the save confirmation")
  key(2, 0); next_frame(context); assert_equal(hint_text(context), "saved buf 3", "K2's release leaves it")
  context.set_time(101.4); redraw()
  assert_equal(hint_text(context), "saved buf 3", "still shown before 1.5 s")
  context.set_time(101.5); redraw()
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the normal hint after 1.5 s")
  -- an empty buffer: nothing saved, the hint says so
  context.polls.fire("bufferState", 200)  -- buffer 3 reports 0 s
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "an empty buffer is not saved")
  assert_equal(hint_text(context), "buf 3 empty", "the hint says the buffer is empty")
  assert_screen_layout(context, "BUFFER with the empty-buffer flash")
  -- one clock ends the flash: it sleeps 1.5 s, clears the flash (even if it
  -- woke a little early) and asks for a redraw
  local slot = S.lib.ui_flash.slots.hints
  local flash_clock = slot.clock
  assert_true(flash_clock ~= nil, "the flash has a clock")
  local flash_sleep
  for _, entry in ipairs(context.clock.sleep_log) do
    if entry.id == flash_clock then flash_sleep = entry.amount end
  end
  assert_near(flash_sleep, 1.5, 1e-9, "it sleeps 1.5 s")
  key(2, 1); tap(3); key(2, 0)   -- a second flash replaces the first one's clock
  assert_equal(context.clock.threads[flash_clock], nil, "the earlier clock is canceled")
  flash_clock = slot.clock
  context.clock.advance_until(flash_clock)        -- the flash clock wakes 1.5 s later
  assert_equal(context.clock.threads[flash_clock], nil, "the clock ends after one wake")
  assert_equal(slot.clock, nil)
  next_frame(context)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the next frame shows the normal hint")
  assert_true(#page_dots(context) == 8, "the hint flash leaves the header alone")
  -- cleanup cancels a pending flash clock
  key(2, 1); tap(3); key(2, 0)
  flash_clock = slot.clock
  cleanup()
  assert_equal(context.clock.threads[flash_clock], nil, "cleanup cancels the flash clock")
  assert_equal(slot.clock, nil)
end)

test("BUFFER changes reach the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local grid_device = context.grid.plug(1, 16, 16)
  show_page("BUFFER")
  h.assert_drawn_on_next_frame(context, arc_hardware, "bufferState report", function()
    context.polls.fire("bufferState", 305)
  end)
  assert_true(h.screen_shows(context, "5.0s"), "BUFFER shows the reported seconds")
  -- voice 1 records into slot 1; no report comes, so the take settles empty
  params:set("v1_source", 2)
  record_buffer(1)
  h.assert_drawn_on_next_frame(context, arc_hardware, "recording timer end", function()
    h.wake_buffer_clock(context, 1)
  end)
  assert_true(h.screen_shows(context, "K2:load K3:... K2+3:save"), "BUFFER shows the take finishing")
  h.assert_drawn_on_next_frame(context, arc_hardware, "fallback settle", function()
    h.wake_buffer_clock(context, 1)
  end)
  assert_true(h.screen_shows(context, "K2:load K3:rec K2+3:save"), "BUFFER shows the take settled")
  assert_true(grid_device.refresh_count > 0, "the grid still redraws on its own")
end)

test("a K2 released inside the norns menu is forgotten: K3 records again (fix round 1)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  local drift_metro = local_value("drift_metro")
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens the menu: the K2 release goes to the menu
  key(2, 1)
  context.menu.mode = true; drift_metro.event()   -- a 10 Hz tick while the menu is open
  context.menu.mode = false                       -- K1 again: back to the script
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save after K2 was released in the menu")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  assert_equal(context.fileselect.last, nil, "nothing opened the file selector")
  -- a save made with K2 held, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 still saves")
  context.menu.mode = true; drift_metro.event(); context.menu.mode = false
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector after the menu")
  -- ticks with the menu closed keep a held K2
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); drift_metro.event(); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2 still held across a tick with the menu closed")
  key(2, 0); assert_equal(context.fileselect.last, nil)
  assert_equal(norns.menu.status(), false, "stub norns.menu.status mirrors _menu.mode")
end)

test("opening the norns menu forgets held keys at once; cleanup restores _menu.set_mode", function()
  local stub_set_mode
  local context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  finish_startup(context); show_page("BUFFER")
  assert_true(_menu.set_mode ~= stub_set_mode, "init watches _menu.set_mode")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens and closes the menu between two 10 Hz ticks
  key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the wrapped set_mode still opens the menu")
  assert_equal(local_value("key_press_page")[2], nil, "the held K2 is forgotten as the menu opens")
  _menu.set_mode(false)
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  -- a K2+K3 save, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1)
  _menu.set_mode(true); _menu.set_mode(false)
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector")
  -- closing the menu forgets nothing (only an opening does)
  key(2, 1); _menu.set_mode(false)
  assert_equal(local_value("key_press_page")[2], local_value("UI_PAGES").index.BUFFER, "set_mode(false) keeps a held key")
  key(2, 0)
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

end

-- test/unit/ui_header_test.lua
-- The header every page shares (lib/ui/header.lua): the page dots, the
-- [M], play and REC indicators, a page's header_status, the scene
-- indicator; and the flashes (lib/ui/flash.lua) in the header and the hint
-- row. Also the screen stub's filled/outlined marks the tests read.
-- Run alone: lua test/run.lua ui_header

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local next_frame, show_page, hint_text, tap = h.next_frame, h.show_page, h.hint_text, h.tap
local assert_screen_layout, texts_on_row, text_span = h.assert_screen_layout, h.texts_on_row, h.text_span
local PAGE_TITLES = h.PAGE_TITLES

-- The rects drawn in the header band (above y 9), in drawing order
local function header_rects(context)
  local found = {}
  for _, rect in ipairs(context.screen.rects) do
    if rect.y + rect.h <= 9 then table.insert(found, rect) end
  end
  return found
end

-- The page dots: the header's 2x2 rects
local function page_dots(context)
  local dots = {}
  for _, rect in ipairs(header_rects(context)) do
    if rect.w == 2 and rect.h == 2 then table.insert(dots, rect) end
  end
  table.sort(dots, function(a, b) return a.x < b.x end)
  return dots
end

-- The header rects that are not page dots (the play mark), as
-- {left, right (exclusive), top, bottom (exclusive), all_filled, count}
local function play_mark(context)
  local mark
  for _, rect in ipairs(header_rects(context)) do
    if not (rect.w == 2 and rect.h == 2) then
      mark = mark or { left = math.huge, right = -math.huge, top = math.huge, bottom = -math.huge,
        all_filled = true, count = 0, area = 0 }
      mark.left = math.min(mark.left, rect.x); mark.right = math.max(mark.right, rect.x + rect.w)
      mark.top = math.min(mark.top, rect.y); mark.bottom = math.max(mark.bottom, rect.y + rect.h)
      mark.all_filled = mark.all_filled and rect.filled == true
      mark.count = mark.count + 1; mark.area = mark.area + rect.w * rect.h
    end
  end
  return mark
end

-- The header text (y 8) whose text is `text`, or nil
local function header_text(context, text)
  for _, entry in ipairs(texts_on_row(context, 8)) do
    if entry.text == text then return entry end
  end
end

-- The header texts at y 8 starting with `prefix`
local function header_text_starting(context, prefix)
  for _, entry in ipairs(texts_on_row(context, 8)) do
    if entry.text:sub(1, #prefix) == prefix then return entry end
  end
end

-- Watch the global request_redraw: counter.calls counts calls until restore()
local function count_redraw_requests()
  local counter = { calls = 0 }
  local real = request_redraw
  request_redraw = function(...) counter.calls = counter.calls + 1; return real(...) end
  function counter.restore() request_redraw = real end
  return counter
end

test("the header constants are the plan's", function()
  load_strata()
  local HEADER = local_value("S").constants.HEADER
  local expected = { dots_x = 40, dot_spacing = 4, dot_size = 2, dot_level = 3, current_dot_level = 15,
    mutation_x = 76, play_x = 90, rec_x = 96, scene_right = 127, status_x = 79, status_play_x = 74,
    flash_x = 40, flash_width = 74, flash_seconds = 1.5 }
  for name, value in pairs(expected) do
    assert_equal(HEADER[name], value, "HEADER." .. name)
  end
end)

test("the header draws eight page dots with the current one bright", function()
  local context = load_strata(); finish_startup(context)
  show_page("SEQ")
  local dots = page_dots(context)
  assert_equal(#dots, 8, "eight page dots")
  for index, dot in ipairs(dots) do
    assert_equal(dot.x, 40 + (index - 1) * 4, "dot " .. index .. " x")
    assert_equal(dot.w, 2); assert_equal(dot.h, 2)
    assert_true(dot.filled == true, "dot " .. index .. " is filled")
    assert_equal(dot.level, index == 3 and 15 or 3, "dot " .. index .. " level on SEQ")
  end
  assert_equal(dots[3].x, 48, "SEQ's dot at x 48")
  -- every page: its own dot bright, the rest dim
  for page = 1, #PAGE_TITLES do
    show_page(page)
    dots = page_dots(context)
    assert_equal(#dots, 8, PAGE_TITLES[page] .. ": eight dots")
    for index, dot in ipairs(dots) do
      assert_equal(dot.level, index == page and 15 or 3, PAGE_TITLES[page] .. ": dot " .. index)
    end
    assert_screen_layout(context, PAGE_TITLES[page] .. " dots")
  end
end)

test("the header shows [M], the play mark and REC only while active", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MAIN")
  assert_equal(header_text(context, "[M]"), nil, "no [M] while mutations are off")
  assert_equal(play_mark(context), nil, "no play mark while stopped")
  assert_equal(header_text(context, "REC"), nil, "no REC while nothing records")
  assert_equal(header_text_starting(context, "dens:"), nil, "the header no longer shows dens:")

  params:set("mutation_enabled", 1); redraw()
  local mutation = header_text(context, "[M]")
  assert_true(mutation, "[M] while mutations run")
  assert_equal(mutation.x, 76, "[M] at x 76")

  pattern_toggle(); redraw()
  local mark = play_mark(context)
  assert_true(mark, "a play mark while patterns play")
  assert_equal(mark.left, 90, "the play mark starts at x 90")
  assert_equal(mark.right, 93, "and ends at x 92")
  assert_equal(mark.bottom - mark.top, 5, "5 px tall")
  assert_true(mark.all_filled, "filled")
  assert_equal(mark.area, 9, "a 3x5 triangle: columns of 5, 3 and 1 px")

  S.buffers[1].recording = true; redraw()
  local rec = header_text(context, "REC")
  assert_true(rec, "REC while a slot records")
  assert_equal(rec.x, 96, "REC at x 96"); assert_equal(rec.level, 15, "REC at level 15")
  S.current_scene = 8; redraw()
  assert_screen_layout(context, "every indicator and S8")

  S.buffers[1].recording = false; S.buffers[8].recording = true; redraw()
  assert_true(header_text(context, "REC"), "any slot recording shows REC")
  S.buffers[8].recording = false
  pattern_toggle(); params:set("mutation_enabled", 0); redraw()
  assert_equal(header_text(context, "[M]"), nil, "[M] gone")
  assert_equal(play_mark(context), nil, "play mark gone")
  assert_equal(header_text(context, "REC"), nil, "REC gone")
end)

test("a page's header_status replaces [M], the play mark and REC", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.registry.pages[S.constants.UI_PAGES.index.SEQ]
  local status = "120 bpm"
  record.header_status = function() return status end
  params:set("mutation_enabled", 1); S.buffers[2].recording = true; S.current_scene = 8
  show_page("SEQ")
  local shown = header_text(context, "120 bpm")
  assert_true(shown, "the status text"); assert_equal(shown.x, 79, "at x 79")
  assert_equal(header_text(context, "[M]"), nil, "no [M]")
  assert_equal(header_text(context, "REC"), nil, "no REC")
  assert_equal(play_mark(context), nil, "no play mark while stopped")
  assert_equal(#page_dots(context), 8, "the dots stay")
  assert_screen_layout(context, "SEQ with a status")
  pattern_toggle(); redraw()
  local mark = play_mark(context)
  assert_true(mark, "the play mark while playing")
  assert_equal(mark.left, 74, "at x 74"); assert_equal(mark.right, 77)
  status = "300 bpm"; redraw(); assert_screen_layout(context, "SEQ at 300 bpm")
  -- a status too wide is cut before the scene indicator
  status = string.rep("w", 20); redraw()
  local cut = header_text_starting(context, "w")
  assert_true(cut and #cut.text < 20, "a long status is cut")
  assert_screen_layout(context, "SEQ with a long status")
  -- nil: the usual indicators
  status = nil; redraw()
  assert_true(header_text(context, "[M]") and header_text(context, "REC"), "the indicators come back")
  assert_equal(play_mark(context).left, 90)
  -- other pages never show it
  show_page("MAIN")
  assert_true(header_text(context, "[M]"), "MAIN shows the indicators")
end)

test("a header flash replaces dots and indicators for 1.5 s", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("mutation_enabled", 1); S.current_scene = 3
  show_page("SEQ")
  header_flash("tempo 121"); redraw()
  local flash = header_text(context, "tempo 121")
  assert_true(flash, "the flash text"); assert_equal(flash.x, 40, "at x 40")
  assert_equal(#page_dots(context), 0, "no dots while it shows")
  assert_equal(header_text(context, "[M]"), nil, "no indicators while it shows")
  assert_true(header_text(context, "S3"), "the scene indicator stays")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 121")
  assert_equal(S.lib.ui_flash.text("hints"), nil, "the hint row's slot is separate")
  assert_screen_layout(context, "SEQ with a header flash")
  next_frame(context)
  local counter = count_redraw_requests()
  context.clock.run_for(1.51)
  counter.restore()
  assert_true(counter.calls >= 1, "the flash's end asks for a redraw")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the flash is over")
  next_frame(context)
  assert_equal(header_text(context, "tempo 121"), nil, "the next frame draws it away")
  assert_equal(#page_dots(context), 8, "dots back")
  assert_true(header_text(context, "[M]"), "indicators back")
end)

test("a new flash replaces the running one and its clock", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local flash_clocks = {}
  local function live_flash_clocks()
    local live = 0
    for id in pairs(flash_clocks) do
      if context.clock.events[id] or context.clock.threads[id] then live = live + 1 end
    end
    return live
  end
  header_flash("a")
  local first = S.lib.ui_flash.slots.header.clock
  assert_true(first, "the flash has a clock"); flash_clocks[first] = true
  local flash_sleep
  for _, entry in ipairs(context.clock.sleep_log) do
    if entry.id == first then flash_sleep = entry.amount end
  end
  assert_near(flash_sleep, 1.5, 1e-9, "it sleeps 1.5 s")
  assert_equal(live_flash_clocks(), 1)
  context.clock.run_for(1.0)
  header_flash("b")
  local second = S.lib.ui_flash.slots.header.clock
  flash_clocks[second] = true
  assert_true(second ~= first, "a new clock")
  assert_equal(context.clock.threads[first], nil, "the first clock is canceled")
  assert_equal(context.clock.events[first], nil)
  assert_equal(live_flash_clocks(), 1, "one flash clock at a time")
  context.clock.run_for(1.0)
  assert_equal(live_flash_clocks(), 1, "still one")
  next_frame(context)
  assert_true(header_text(context, "b"), "b still shown 1 s after it started")
  assert_equal(header_text(context, "a"), nil)
  context.clock.run_for(0.51)
  assert_equal(live_flash_clocks(), 0, "the clock ended")
  assert_equal(S.lib.ui_flash.text("header"), nil, "gone 1.5 s after b")
  next_frame(context)
  assert_equal(header_text(context, "b"), nil, "and drawn away")
  -- a start with its own length; cleanup cancels every slot's clock
  S.lib.ui_flash.start("hints", "hint", 2)
  header_flash("c")
  local hints_clock, header_clock = S.lib.ui_flash.slots.hints.clock, S.lib.ui_flash.slots.header.clock
  context.clock.run_for(1.9)
  assert_equal(S.lib.ui_flash.text("hints"), "hint", "a 2 s flash is still up at 1.9 s")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the 1.5 s one is not")
  header_flash("d")
  header_clock = S.lib.ui_flash.slots.header.clock
  cleanup()
  assert_equal(context.clock.threads[hints_clock], nil, "cleanup cancels the hints clock")
  assert_equal(context.clock.threads[header_clock], nil, "and the header clock")
  assert_equal(S.lib.ui_flash.slots.hints.clock, nil); assert_equal(S.lib.ui_flash.slots.header.clock, nil)
  assert_equal(S.lib.ui_flash.text("header"), nil)
end)

test("an unknown flash slot is an error", function()
  load_strata()
  local S = local_value("S")
  assert_true(not pcall(S.lib.ui_flash.start, "footer", "x", 1), "start")
  assert_true(not pcall(S.lib.ui_flash.text, "footer"), "text")
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

test("a hints flash shows only on its owning page", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local BUFFER = S.constants.UI_PAGES.index.BUFFER
  for page = 1, #PAGE_TITLES do
    show_page(page)
    buffer_page_flash("buf 2 load failed"); redraw()
    if page == BUFFER then
      assert_equal(hint_text(context), "buf 2 load failed", "BUFFER shows its flash")
    else
      assert_equal(hint_text(context), S.registry.pages[page].hints(false),
        PAGE_TITLES[page] .. " shows its own hints, not BUFFER's flash")
    end
    assert_screen_layout(context, PAGE_TITLES[page] .. " with BUFFER's hints flash")
  end
  -- raised on SETUP, then BUFFER shown within 1.5 s: it shows there
  show_page("SETUP"); buffer_page_flash("buf 2 load failed")
  show_page("BUFFER"); assert_equal(hint_text(context), "buf 2 load failed", "BUFFER shows it once up")
  show_page("SETUP"); assert_equal(hint_text(context), "E2:port E3:ch K3:save", "SETUP never does")
  -- a page-owned prompt (as SCENES will raise) stays on its page
  local SCENES = S.constants.UI_PAGES.index.SCENES
  show_page("SCENES"); S.lib.ui_flash.start("hints", "K3 again: overwrite S3", 2, SCENES); redraw()
  assert_equal(hint_text(context), "K3 again: overwrite S3")
  show_page("SETUP"); assert_equal(hint_text(context), "E2:port E3:ch K3:save", "not over SETUP's keys")
  -- without a page, a hints flash shows on whatever page is up
  S.lib.ui_flash.start("hints", "anywhere", 1.5); redraw()
  assert_equal(hint_text(context), "anywhere", "an unowned flash shows on SETUP")
  context.clock.run_for(1.51); next_frame(context)
  assert_equal(hint_text(context), "E2:port E3:ch K3:save", "the page's hints come back")
end)

test("a nil flash text ends the flash instead of showing nil", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  header_flash("a"); local running = S.lib.ui_flash.slots.header.clock
  header_flash(nil); redraw()
  assert_equal(S.lib.ui_flash.text("header"), nil, "no flash")
  assert_equal(header_text(context, "nil"), nil, "never the text nil")
  assert_equal(context.clock.threads[running], nil, "the running flash's clock is canceled")
  assert_equal(S.lib.ui_flash.slots.header.clock, nil, "and none started")
  assert_equal(#page_dots(context), 8, "the dots show")
  show_page("BUFFER"); buffer_page_flash(nil); redraw()
  assert_true(hint_text(context) ~= "nil", "the hint row never shows nil")
end)

test("a long flash text is cut to end before the scene indicator", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.current_scene = 8
  for page = 1, #PAGE_TITLES do
    show_page(page)
    header_flash(string.rep("x", 40)); redraw()
    local shown = header_text_starting(context, "x")
    assert_true(shown, "the flash is drawn")
    assert_true(#shown.text < 40, "and cut")
    local _, right = text_span(shown)
    assert_true(right <= 40 + 74, "it ends by x 114")
    assert_screen_layout(context, PAGE_TITLES[page] .. " with a long header flash and S8")
  end
end)

test("the screen stub records filled and outlined rects", function()
  local context = load_strata()
  screen.clear()
  screen.rect(0, 0, 4, 4); screen.fill()
  screen.rect(5, 0, 4, 4); screen.stroke()
  screen.move(0, 10); screen.line(10, 10); screen.stroke()
  screen.move(0, 12); screen.line(10, 12); screen.fill()
  screen.rect(20, 0, 2, 2)
  local rects, lines = context.screen.rects, context.screen.lines
  assert_equal(rects[1].filled, true, "a filled rect")
  assert_equal(rects[2].filled, false, "an outlined rect")
  assert_equal(lines[1].filled, false, "a stroked line")
  assert_equal(lines[2].filled, true, "a filled path")
  assert_equal(rects[3].filled, nil, "not drawn yet")
  -- a fill marks only the path since the last fill or stroke
  screen.rect(30, 0, 2, 2); screen.stroke()
  assert_equal(rects[3].filled, false); assert_equal(rects[4].filled, false)
  assert_equal(rects[1].filled, true, "earlier marks stay")
  screen.clear()
  screen.rect(0, 0, 1, 1); screen.fill()
  assert_equal(#context.screen.rects, 1); assert_equal(context.screen.rects[1].filled, true)
end)
end

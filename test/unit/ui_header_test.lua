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
  local expected = { dots_x = 36, dot_spacing = 4, dot_size = 2, dot_level = 3, current_dot_level = 15,
    mutation_x = 76, play_x = 90, rec_x = 96, scene_right = 127, status_x = 79, status_play_x = 73,
    flash_x = 40, flash_width = 74, flash_seconds = 1.5 }
  for name, value in pairs(expected) do
    assert_equal(HEADER[name], value, "HEADER." .. name)
  end
end)

test("the header draws nine page dots with the current one bright", function()
  local context = load_strata(); finish_startup(context)
  show_page("SEQ")
  local dots = page_dots(context)
  assert_equal(#dots, 9, "nine page dots")
  for index, dot in ipairs(dots) do
    assert_equal(dot.x, 36 + (index - 1) * 4, "dot " .. index .. " x")
    assert_equal(dot.w, 2); assert_equal(dot.h, 2)
    assert_true(dot.filled == true, "dot " .. index .. " is filled")
    assert_equal(dot.level, index == 3 and 15 or 3, "dot " .. index .. " level on SEQ")
  end
  assert_equal(dots[3].x, 44, "SEQ's dot at x 44")
  -- every page: its own dot bright, the rest dim
  for page = 1, #PAGE_TITLES do
    show_page(page)
    dots = page_dots(context)
    assert_equal(#dots, 9, PAGE_TITLES[page] .. ": nine dots")
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

-- #254: a 2 s fade has 20 steps of 0.1 s; the first runs inside the recall
test("the scene a fade goes to blinks in the header, one change per step", function()
  local context = load_strata(); finish_startup(context)
  capture_scene(1); capture_scene(2)
  recall_scene(1, 0); recall_scene(2, 2)
  context.clock.run_for(0.1); redraw()                          -- step 2
  local mark = header_text(context, "S2")
  assert_true(mark, "the target's mark is drawn while dark")
  assert_equal(mark.level, 2, "step 2: the mark is dark")
  assert_screen_layout(context, "the header while the fading target is dark")
  context.clock.run_for(0.1); redraw()                          -- step 3
  assert_equal(header_text(context, "S2").level, 6, "step 3: its level with the sequencer off")
  assert_screen_layout(context, "the header while the fading target shows")
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
  assert_equal(#page_dots(context), 9, "the dots stay")
  assert_screen_layout(context, "SEQ with a status")
  pattern_toggle(); redraw()
  local mark = play_mark(context)
  assert_true(mark, "the play mark while playing")
  assert_equal(mark.left, 73, "at x 73"); assert_equal(mark.right, 76)
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
  assert_equal(header_text(context, "120 bpm"), nil, "no SEQ status while it shows")
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
  assert_equal(#page_dots(context), 9, "dots back")
  assert_true(header_text(context, "120 bpm"), "SEQ's status back")
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

test("a hints flash shows only on its owning page", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local BUFFER = S.constants.UI_PAGES.index.BUFFER
  local setup_hints = S.registry.pages[S.constants.UI_PAGES.index.SETUP].hints(false)
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
  show_page("SETUP"); assert_equal(hint_text(context), setup_hints, "SETUP never does")
  -- a page-scoped hints flash (as BUFFER's load reports raise) stays on its page
  local SCENES = S.constants.UI_PAGES.index.SCENES
  show_page("SCENES"); S.lib.ui_flash.start("hints", "scenes note", 2, SCENES); redraw()
  assert_equal(hint_text(context), "scenes note")
  show_page("SETUP"); assert_equal(hint_text(context), setup_hints, "not over SETUP's keys")
  -- without a page, a hints flash shows on whatever page is up
  S.lib.ui_flash.start("hints", "anywhere", 1.5); redraw()
  assert_equal(hint_text(context), "anywhere", "an unowned flash shows on SETUP")
  context.clock.run_for(1.51); next_frame(context)
  assert_equal(hint_text(context), setup_hints, "the page's hints come back")
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
  assert_equal(#page_dots(context), 9, "the dots show")
  show_page("BUFFER"); buffer_page_flash(nil); redraw()
  assert_true(hint_text(context) ~= "nil", "the hint row never shows nil")
end)

-- A standing notice (MOD's learn waiting, ruling 80): in its slot whenever
-- no flash shows there, on every page, for exactly as long as it gives a text
test("a standing notice shows under any flash, on every page, while it gives a text", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local standing = nil
  S.lib.ui_flash.add_notice("header", function() return standing end)
  show_page("FX")
  assert_equal(S.lib.ui_flash.text("header"), nil, "nothing while it gives nil")
  assert_equal(#page_dots(context), 9, "the dots show")
  standing = "a notice"; redraw()
  local shown = header_text(context, "a notice")
  assert_true(shown, "the notice is drawn"); assert_equal(shown.x, 40, "where a flash is")
  assert_equal(#page_dots(context), 0, "in place of the dots")
  assert_equal(S.lib.ui_flash.text("header"), "a notice", "what the slot shows")
  assert_equal(S.lib.ui_flash.slots.header.clock, nil, "a notice has no clock")
  assert_screen_layout(context, "FX with a standing notice")
  header_flash("a flash"); redraw()
  assert_true(header_text(context, "a flash") and not header_text(context, "a notice"), "a flash shows over it")
  context.clock.run_for(1.51); next_frame(context)
  assert_true(header_text(context, "a notice"), "and the notice is back once the flash ends")
  show_page("SETUP")
  assert_true(header_text(context, "a notice"), "on every page")
  standing = string.rep("x", 40); redraw()
  local long = header_text_starting(context, "x")
  assert_true(long and #long.text < 40, "a long notice is cut")
  assert_true(select(2, text_span(long)) <= 40 + 74, "to the flash's width")
  standing = nil; redraw()
  assert_equal(S.lib.ui_flash.text("header"), nil, "gone as soon as it gives nil")
  assert_equal(#page_dots(context), 9, "the dots are back")
  assert_true(not pcall(S.lib.ui_flash.add_notice, "footer", function() end), "an unknown slot is an error")
  assert_true(not pcall(S.lib.ui_flash.add_notice, "header", "text"), "a notice is a function")
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
test("the header shows ARM while a slot is armed and none records", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local function at_rec_x()
    local found = {}
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 96 and entry.y == 8 then table.insert(found, entry.text) end
    end
    return table.concat(found, " ")
  end
  redraw(); assert_equal(at_rec_x(), "", "nothing at x 96")
  params:set("record_threshold", 2)   -- waits for the input's level: armed
  record_buffer(1); redraw()
  assert_equal(at_rec_x(), "ARM", "ARM while slot 1 is armed")
  assert_screen_layout(context, "the header with ARM")
  params:set("record_threshold", 1)
  record_buffer(2); redraw()
  assert_equal(at_rec_x(), "REC", "REC once a slot records, no ARM")
  record_buffer(2); record_buffer(1)   -- stop both
  context.polls.fire("recordState", (1 * 4 + 3) * 8 + 0)   -- slot 1's armed recording canceled
  context.polls.fire("bufferState", context.polls.buffer_state_value(2, 0, 3))  -- slot 2's take settles
  redraw()
  assert_equal(at_rec_x(), "", "neither: nothing at x 96")
end)


test("the hint row is cut to the screen", function()
  local context = load_strata(); finish_startup(context)
  show_page("BUFFER")
  local long = "no files in /home/we/dust/audio/a_long_folder_name/another_long_one/"
  buffer_page_flash(long); redraw()
  local shown = hint_text(context)
  assert_true(#shown < #long and long:sub(1, #shown) == shown, "the flash is cut: " .. shown)
  assert_true(select(2, text_span({ x = 0, text = shown, align = "left" })) <= 128, "and ends on the screen")
  assert_equal(local_value("S").lib.ui_flash.text("hints"), long, "the flash itself keeps its text")
  assert_screen_layout(context, "BUFFER with a long flash")
end)

-- 3.4: the dots move 4 px left (a ninth page comes in 3.4's Wave 2) and the
-- scene runs to S16, 3 px wider than S8 (design §9.1, Question 16)
test("nine dots from x 36 clear the play mark; S16 clears REC", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.registry.pages[S.constants.UI_PAGES.index.SEQ]
  record.header_status = function() return "120 bpm" end
  show_page("SEQ"); pattern_toggle(); redraw()
  local dots = page_dots(context)
  assert_equal(#dots, 9, "nine dots, one per page (3.4's MOD the sixth)")
  assert_equal(dots[1].x, 36, "the first at x 36")
  assert_equal(dots[9].x, 68, "the ninth at x 68")
  local mark = play_mark(context)
  assert_equal(mark.left, 73, "a status's play mark at x 73, the leftmost it goes")
  assert_true(dots[9].x + dots[9].w < mark.left, "the last dot ends clear of it")
  -- on every page the dots clear the title, the widest of them
  for _, name in ipairs(S.constants.UI_PAGES) do
    show_page(name); redraw()
    assert_equal(#page_dots(context), 9, name .. " shows nine dots")
    assert_screen_layout(context, name .. "'s header")
  end
  show_page("SEQ"); redraw()
  record.header_status = nil
  S.current_scene = 16; S.buffers[1].recording = true
  show_page("MAIN"); redraw()
  local rec, scene = header_text(context, "REC"), header_text(context, "S16")
  assert_true(rec and scene, "REC and S16 are drawn")
  local _, rec_right = text_span(rec)
  local scene_left, scene_right = text_span(scene)
  assert_equal(scene_right, 127, "S16 ends at x 127")
  assert_true(rec_right < scene_left, "REC ends before S16 begins")
  assert_screen_layout(context, "every indicator and S16")
  S.buffers[1].recording = false
  params:set("record_threshold", 2); record_buffer(1); redraw()  -- armed: ARM, the wider of the two
  local arm = header_text(context, "ARM")
  assert_true(arm, "ARM is drawn")
  local _, arm_right = text_span(arm)
  assert_true(arm_right < scene_left, "ARM ends before S16 begins")
  assert_screen_layout(context, "ARM and S16")
  header_flash(string.rep("x", 40)); redraw()
  local _, flash_right = text_span(header_text_starting(context, "x"))
  assert_true(flash_right <= scene_left, "a long header flash ends by S16")
  assert_screen_layout(context, "a long header flash and S16")
end)

end

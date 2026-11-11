-- test/unit/pages_lfo_test.lua
-- The LFO page (lib/pages/lfo.lua): its rows, the selected LFO's field
-- strip, keys, hints and drawing; the 25% default depth and the library's
-- offset (lib/lfos.lua)
-- Run alone: lua test/run.lua pages_lfo

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap, hint_text, texts_on_row = h.tap, h.hint_text, h.texts_on_row

-- The strip's fields in order (lib/pages/lfo.lua's LFO_FIELDS)
local FIELD = { dest = 1, shape = 2, mode = 3, rate = 4, depth = 5, offset = 6, state = 7 }

local function pages_lfo() return local_value("S").lib.pages_lfo end

-- Put the strip's cursor on a field (E2 from the first field)
local function strip_field(field)
  enc(2, -10); enc(2, FIELD[field] - 1); redraw()
  assert_equal(local_value("lfo_field"), FIELD[field], "strip cursor on " .. field)
end

-- ALT held around fn (K1 down, fn, K1 up)
local function with_alt(fn)
  key(1, 1); fn(); key(1, 0)
end

-- The strip's texts, left to right (the line under the selected LFO's row)
local function strip_texts(context)
  return texts_on_row(context, pages_lfo().strip_y())
end

test("Strata applies the library's LFO offset", function()
  local context = load_strata(); finish_startup(context)
  params:set("filter_res", 0.5); params:set("strata_lfo1_dest", 5)   -- filt res
  -- (the library's on/off action resets the offset to 0, so set it after)
  params:set("lfo_depth_1", 25); params:set("lfo_1", 2); params:set("lfo_offset_1", 20)
  context.clear_engine_calls(); context.lfo.tick(local_value("lfos")[1], 0.5)   -- the shape's center
  -- the library adds 0.2 * (max - min) = 0.4 to scaled; Strata sends scaled * half the range
  assert_near(context.calls_named("setFilter")[1].args[2], 0.5 + 0.4 * 0.5, 1e-6, "res 0.5 + 0.2")
  assert_near(params:get("filter_res"), 0.5, 1e-9, "param value untouched")
end)

test("LFOs start at 25% depth", function()
  local context = load_strata(); finish_startup(context)
  for n = 1, local_value("NUM_LFOS") do
    assert_equal(params:get("lfo_depth_" .. n), 25, "LFO " .. n .. " depth")
    assert_equal(params:string("lfo_depth_" .. n), "25%", "a whole percent")
    assert_equal(param_default("lfo_depth_" .. n), 25, "its default")
    assert_near(local_value("lfos")[n]:get("depth"), 0.25, 1e-9, "the library's depth")
    assert_equal(params:string("lfo_" .. n), "off", "and still off")
  end
  -- a scene saved with depth 0 still recalls 0
  params:set("lfo_depth_1", 0); capture_scene(1)
  params:set("lfo_depth_1", 40); recall_scene_instant(1)
  assert_equal(params:get("lfo_depth_1"), 0, "a stored depth of 0 recalls 0")
end)

test("group starts come from the destinations list", function()
  load_strata()
  -- each registered destination (3.2's hist, vfilt, dsend, rsend: v1-v7
  -- each, after the 68 built-in ones) is a group of its own (#511)
  assert_equal(#local_value("S").registry.lfo_destinations, 4, "3.2's four registered destinations")
  assert_equal(table.concat(lfo_dest_group_starts(), " "), "1 2 13 21 29 37 45 53 61 69 76 83 90")
  local destinations = local_value("LFO_DESTINATIONS")
  for _, start in ipairs({ 13, 21, 61 }) do
    assert_true(destinations[start].label:find(" main$"), destinations[start].label .. " starts a voice group")
  end
  local registered_labels = { [69] = "v1 hist", [76] = "v1 vfilt", [83] = "v1 dsend", [90] = "v1 rsend" }
  for start, label in pairs(registered_labels) do
    assert_equal(destinations[start].label, label, "a registered group starts at voice 1")
  end
  assert_equal(lfo_dest_group_jump(1, -1), 1, "clamped at none")
  assert_equal(lfo_dest_group_jump(5, 1), 13, "next start above")
  assert_equal(lfo_dest_group_jump(5, -1), 2, "last start below")
  assert_equal(lfo_dest_group_jump(61, 1), 69, "from v7 main on to the registered groups")
  assert_equal(lfo_dest_group_jump(68, -1), 61, "from v7 scan back to v7 main")
  assert_equal(lfo_dest_group_jump(96, 1), 96, "clamped at the last destination")
end)

test("ALT+E3 lands on each registered group's first voice, both ways (#511)", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local function alt_e3(d) with_alt(function() enc(3, d) end) end
  params:set("strata_lfo1_dest", 61)   -- v7 main
  local labels = {}
  for _ = 1, 5 do
    alt_e3(1)
    table.insert(labels, local_value("LFO_DESTINATIONS")[params:get("strata_lfo1_dest")].label)
  end
  assert_equal(table.concat(labels, ", "), "v1 hist, v1 vfilt, v1 dsend, v1 rsend, v1 rsend", "then clamped")
  params:set("strata_lfo1_dest", 96)   -- v7 rsend, the last destination
  alt_e3(-1); assert_equal(params:get("strata_lfo1_dest"), 90, "back to v1 rsend")
  alt_e3(-2); assert_equal(params:get("strata_lfo1_dest"), 76, "two groups back: v1 vfilt")
  params:set("strata_lfo1_dest", 70)   -- v2 hist
  alt_e3(-1); assert_equal(params:get("strata_lfo1_dest"), 69, "inside a group: back to its start")
end)

test("E2 moves along the strip and E3 edits the field both ways", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  assert_equal(local_value("lfo_field"), FIELD.dest, "the strip starts on the destination")
  enc(3, 1); assert_equal(params:get("strata_lfo1_dest"), 2)
  enc(3, -1); assert_equal(params:get("strata_lfo1_dest"), 1)
  enc(3, -1); assert_equal(params:get("strata_lfo1_dest"), 1, "clamped at none, no wrap")
  enc(2, -1); assert_equal(local_value("lfo_field"), FIELD.dest, "E2 stops at the first field")
  enc(2, 1); enc(3, 1); assert_equal(params:string("lfo_shape_1"), "tri", "E3 on shape")
  enc(3, -1); assert_equal(params:string("lfo_shape_1"), "sine")
  enc(2, 1); enc(3, -1); assert_equal(params:string("lfo_mode_1"), "clocked", "E3 on mode")
  enc(2, 1)  -- rate: the clocked division
  local division = params:get("lfo_clocked_1")
  enc(3, 1); assert_equal(params:get("lfo_clocked_1"), division + 1, "E3 steps the clocked rate")
  enc(2, -1); enc(3, 1); enc(2, 1)   -- back to free: the free period
  local period = params:get("lfo_free_1")
  enc(3, 1); assert_true(params:get("lfo_free_1") > period, "E3 lengthens the free period")
  enc(3, -1); assert_near(params:get("lfo_free_1"), period, 1e-6, "and shortens it")
  enc(2, 1); enc(3, 5); assert_equal(params:get("lfo_depth_1"), 30, "E3 on depth, in percent")
  enc(2, 1); enc(3, -3); assert_equal(params:get("lfo_offset_1"), -3, "E3 on offset")
  enc(2, 1); enc(3, 1); assert_equal(params:string("lfo_1"), "on", "E3 on on/off")
  enc(3, -1); assert_equal(params:string("lfo_1"), "off")
  enc(2, 1); assert_equal(local_value("lfo_field"), FIELD.state, "E2 stops at the last field")
  assert_equal(local_value("selected_voice"), 1, "MAIN's voice is untouched")
end)

test("the offset holds at its center detent", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO"); strip_field("offset")
  params:set("lfo_offset_1", 2)
  enc(3, -5); assert_equal(params:get("lfo_offset_1"), 0, "an accelerated turn lands on 0")
  enc(3, -1); assert_equal(params:get("lfo_offset_1"), 0, "and holds there")
end)

test("turning an LFO on or off from the page keeps its offset", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO"); strip_field("offset")
  enc(3, 12); assert_equal(params:get("lfo_offset_1"), 12)
  with_alt(function() tap(3) end)
  assert_equal(params:string("lfo_1"), "on"); assert_equal(params:get("lfo_offset_1"), 12, "ALT+K3 on keeps it")
  context.arc.plug(1); context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(params:string("lfo_1"), "off"); assert_equal(params:get("lfo_offset_1"), 12, "the arc button keeps it")
  strip_field("state"); enc(3, 1)
  assert_equal(params:string("lfo_1"), "on"); assert_equal(params:get("lfo_offset_1"), 12, "E3 on on/off keeps it")
  assert_near(local_value("lfos")[1]:get("offset"), 0.12, 1e-9, "and so does the library")
end)

test("the strip shows as many fields as fit and keeps the cursor's in view", function()
  local context = load_strata(); finish_startup(context)
  params:set("strata_lfo1_dest", 4)   -- filt freq
  show_page("LFO")
  local texts = strip_texts(context)
  assert_equal(texts[1].text, "filt freq", "the destination first")
  assert_equal(texts[1].x, 0)
  assert_equal(texts[1].level, 15, "the cursor's field bright")
  assert_equal(texts[2].text, "sine"); assert_equal(texts[2].level, 4, "the others dim")
  assert_equal(texts[#texts].text, ">", "more fields to the right")
  assert_equal(texts[#texts].align, "right")
  local _, right = text_span(texts[#texts])
  assert_true(right <= 128, "the marker ends inside the screen")
  assert_true(#texts - 1 < 7, "not every field fits")
  for index = 2, #texts do
    local _, previous_right = text_span(texts[index - 1])
    assert_true(select(1, text_span(texts[index])) > previous_right, "fields apart")
  end
  strip_field("state")
  texts = strip_texts(context)
  assert_equal(texts[1].text, "<", "fields off to the left")
  assert_equal(texts[1].x, 0)
  assert_equal(texts[#texts].text, "off", "on/off drawn last")
  assert_equal(texts[#texts].level, 15)
  assert_screen_layout(context, "LFO strip on on/off")
  -- every field in view as the cursor reaches it, with its value
  params:set("lfo_offset_1", 20); params:set("lfo_depth_1", 70)
  local expected = { "filt freq", "sine", "free", "4.0s", "70%", "+20%", "off" }
  for field = 1, 7 do
    enc(2, -10); enc(2, field - 1); redraw()
    local found
    for _, entry in ipairs(strip_texts(context)) do
      if entry.level == 15 then found = entry.text end
    end
    assert_equal(found, expected[field], "field " .. field .. " shown bright")
    assert_screen_layout(context, "LFO strip field " .. field)
  end
  -- a clocked rate shows its division
  params:set("lfo_mode_1", 1); params:set("lfo_clocked_1", 5)
  strip_field("rate")
  local bright
  for _, entry in ipairs(strip_texts(context)) do
    if entry.level == 15 then bright = entry.text end
  end
  assert_equal(bright, params:string("lfo_clocked_1"), "the clocked division")
  assert_equal(bright, "1/3")
  -- the strip follows the selected LFO
  tap(3); redraw()
  assert_equal(pages_lfo().strip_y(), pages_lfo().row_top(2) + pages_lfo().layout.strip_baseline,
    "the strip under LFO 2's row")
end)

test("ALT+E3 on the destination jumps a group", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local function alt_e3(d) with_alt(function() enc(3, d) end) end
  alt_e3(1); assert_equal(params:get("strata_lfo1_dest"), 2, "none to the first global")
  alt_e3(1); assert_equal(params:get("strata_lfo1_dest"), 13, "to v1 main")
  alt_e3(1); assert_equal(params:get("strata_lfo1_dest"), 21, "to v2 main")
  params:set("strata_lfo1_dest", 15)
  alt_e3(-1); assert_equal(params:get("strata_lfo1_dest"), 13, "back to its group's start")
  alt_e3(-1); assert_equal(params:get("strata_lfo1_dest"), 2, "then the globals")
  local starts = lfo_dest_group_starts()
  params:set("strata_lfo1_dest", starts[#starts]); alt_e3(1)
  assert_equal(params:get("strata_lfo1_dest"), starts[#starts], "clamped at the last group (v7, or the registered ones)")
  -- on another field ALT+E3 is fine adjustment (a control) or whole steps
  strip_field("rate")
  params:set("lfo_free_1", 100)   -- long enough for a fine step to pass the 0.1 s step
  local period = params:get("lfo_free_1")
  enc(3, 1); local coarse = params:get("lfo_free_1") - period
  enc(3, -1)
  alt_e3(1); local fine = params:get("lfo_free_1") - period
  assert_true(fine > 0 and fine < coarse, "ALT+E3 moves the free period finer")
  strip_field("depth"); alt_e3(2)
  assert_equal(params:get("lfo_depth_1"), 27, "a number param keeps whole steps")
end)

test("K2 and K3 select the LFO and forget ring 4's carried ticks", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("LFO")
  tap(2); assert_equal(S.selected_lfo, 1, "K2 stops at LFO 1")
  S.arc_ticks["lfo:4"] = 15; S.arc_ticks["lfo:1"] = 5
  tap(3); assert_equal(S.selected_lfo, 2, "K3: the next LFO")
  assert_equal(S.arc_ticks["lfo:4"], nil, "ring 4's ticks forgotten")
  assert_equal(S.arc_ticks["lfo:1"], 5, "the depth rings keep theirs")
  tap(3); tap(3); assert_equal(S.selected_lfo, 3, "K3 stops at the last LFO")
  S.arc_ticks["lfo:4"] = 15
  tap(3); assert_equal(S.arc_ticks["lfo:4"], 15, "no change, nothing forgotten")
  tap(2); assert_equal(S.selected_lfo, 2, "K2: the previous LFO")
  assert_equal(S.arc_ticks["lfo:4"], nil)
  strip_field("depth"); enc(3, 3)
  assert_equal(params:get("lfo_depth_2"), 28, "the strip edits the selected LFO")
  assert_equal(params:get("lfo_depth_1"), 25, "and leaves the others")
  for n = 1, 3 do assert_equal(params:string("lfo_" .. n), "off", "K2/K3 turn nothing on") end
end)

test("ALT+K2 resets the field; ALT+K3 turns the LFO on and off", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  strip_field("depth"); params:set("lfo_depth_1", 70)
  with_alt(function() tap(2) end)
  assert_equal(params:get("lfo_depth_1"), 25, "depth back to its default")
  strip_field("dest"); params:set("strata_lfo1_dest", 30)
  with_alt(function() tap(2) end)
  assert_equal(params:get("strata_lfo1_dest"), 1, "destination back to none")
  strip_field("rate"); params:set("lfo_free_1", 30)
  with_alt(function() tap(2) end)
  assert_near(params:get("lfo_free_1"), 4, 1e-9, "free period back to 4 s")
  strip_field("offset"); params:set("lfo_offset_1", -12)
  with_alt(function() tap(2) end)
  assert_equal(params:get("lfo_offset_1"), 0, "offset back to 0")
  with_alt(function() tap(3) end)
  assert_equal(params:string("lfo_1"), "on", "ALT+K3 turns the LFO on")
  with_alt(function() tap(3) end)
  assert_equal(params:string("lfo_1"), "off", "and off")
  -- the arc button does what ALT+K3 does
  context.arc.plug(1)
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(params:string("lfo_1"), "on", "the arc button turns the selected LFO on")
  tap(3); context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(params:string("lfo_2"), "on", "the selected one")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(params:string("lfo_2"), "off")
end)

test("LFO hints", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  assert_equal(hint_text(context), "K2/K3:lfo E3:dest")
  enc(2, 1); redraw(); assert_equal(hint_text(context), "K2/K3:lfo E3:shape")
  local labels = { "dest", "shape", "mode", "rate", "depth", "offset", "on/off" }
  for field = 1, 7 do
    enc(2, -10); enc(2, field - 1); redraw()
    assert_equal(hint_text(context), "K2/K3:lfo E3:" .. labels[field])
  end
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:reset K3:on")
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:reset K3:off")
  key(1, 0); enc(2, -10); key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:reset K3:off E3:group", "the destination's ALT+E3 group jump")
  local _, right = text_span({ x = 0, text = hint_text(context) })
  assert_true(right <= 128, "the longest ALT hint fits")
  key(1, 0)
end)

test("the LFO page redraws on every frame only while an LFO runs, with no clock of its own (#423)", function()
  local context = load_strata(); finish_startup(context)
  local baseline = context.clock.pending_count()
  show_page("LFO")
  assert_equal(context.clock.pending_count(), baseline, "no page clock: the frame clock draws it")
  next_frame(context)
  local counter = count_screen_draws()
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 0, "no LFO runs: an idle frame draws nothing")
  params:set("lfo_2", 2); next_frame(context)
  counter.screen = 0
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 2, "an LFO runs: each frame redraws, so its dot moves")
  params:set("lfo_2", 1); next_frame(context)
  assert_equal(counter.screen, 3, "turning it off draws once, without its dot")
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 3, "then the page is idle again")
  params:set("lfo_3", 2); show_page("BUFFER"); next_frame(context)
  counter.screen = 0
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "other pages draw only when asked, LFOs running or not")
end)

-- The LFO page's waveform, dot and labels for LFO n
local function lfo_row_drawing(context, n)
  local top = pages_lfo().row_top(n)
  local row = { lines = {}, rects = {}, texts = {} }
  for _, line in ipairs(context.screen.lines) do
    if line.y1 >= top and line.y1 <= top + 10 then table.insert(row.lines, line) end
  end
  for _, rect in ipairs(context.screen.rects) do
    if rect.y >= top - 1 and rect.y <= top + 10 then table.insert(row.rects, rect) end
  end
  for _, entry in ipairs(context.screen.texts) do
    if entry.y > top and entry.y <= top + 11 then table.insert(row.texts, entry.text) end
  end
  return row
end

-- Rows and strip lie between the header (y 8) and the hint row's glyphs
local BODY_TOP, BODY_BOTTOM = 10, HINT_ROW_Y - TEXT_HEIGHT

test("LFO page rows: waveform, dot from the last raw value and elapsed period, labels; cleanup stops LFOs", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  context.set_time(100)
  params:set("strata_lfo1_dest", 4); params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 0.25)
  show_page("LFO")
  -- three rows, each labeled, and every string inside the screen
  for n = 1, 3 do
    local row = lfo_row_drawing(context, n)
    assert_true(table.concat(row.texts, " "):find("L" .. n, 1, true), "row " .. n .. " labeled L" .. n)
    assert_true(#row.lines >= 63, "row " .. n .. " draws its waveform")
  end
  for _, entry in ipairs(context.screen.texts) do
    local left, right = text_span(entry)
    assert_true(left >= 0 and right <= 128 and entry.y <= 64, "'" .. entry.text .. "' inside the screen")
  end
  -- every drawn shape stays inside the page body
  for _, line in ipairs(context.screen.lines) do
    assert_true(line.y1 >= BODY_TOP and line.y2 <= BODY_BOTTOM and line.y2 >= BODY_TOP and line.y1 <= BODY_BOTTOM,
      "line inside the body")
    assert_true(line.x1 >= 12 and line.x2 <= 75, "waveform inside x 12-75")
  end
  local row = lfo_row_drawing(context, 1)
  assert_true(#row.lines >= 63, "64 px waveform ")
  assert_equal(#row.rects, 1, "one dot for a running LFO")
  local top = pages_lfo().row_top(1)
  -- reset to the floor (phase 0.75) at t 100, so at t 100 the dot is at 0.75
  local dot = row.rects[1]
  assert_near(dot.x + 1, 12 + 0.75 * 63, 0.51, "dot x from the phase since the reset")
  -- raw 0.25 swings a quarter below the middle line at full depth: half that at 50 %
  assert_near(dot.y + 1, top + 10 - (0.5 - 0.25 * 0.5) * 10, 0.51, "dot y from the last raw value and the depth")
  assert_true(table.concat(row.texts, " "):find("filt freq"), "destination label")
  assert_true(table.concat(row.texts, " "):find("on 50%%"), "state and depth")
  -- one second later at a 4 s period: a quarter cycle further, wrapped to 0
  context.set_time(101); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12, 0.51, "dot advanced and wrapped")
  -- a period change keeps the phase (like the library), then advances at the new rate
  params:set("lfo_free_1", 2)
  context.set_time(101.5); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.25 * 63, 0.51, "advances at the new period")
  -- the phase offset shifts the dot, the reset trigger restarts it
  params:set("lfo_phase_1", 50); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "phase offset")
  params:set("lfo_phase_1", 0); params:set("lfo_reset_1", 1); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "reset to the floor")
  -- stopped LFOs draw no dot
  assert_equal(#lfo_row_drawing(context, 2).rects, 0, "no dot for a stopped LFO")
  assert_true(table.concat(lfo_row_drawing(context, 2).texts, " "):find("off 25%%"), "stopped LFO shows off")
  -- every shape and every destination label, under each selected LFO, keeps
  -- the page apart and inside the screen
  for selected = 1, 3 do
    local_value("S").selected_lfo = selected
    for shape = 1, 6 do
      for n = 1, 3 do params:set("lfo_shape_" .. n, shape) end
      for _, dest in ipairs({ 1, 3, 12, 17, 68 }) do
        params:set("strata_lfo2_dest", dest); params:set("lfo_depth_2", 100); redraw()
        assert_screen_layout(context, "LFO " .. selected .. " selected, shape " .. shape .. ", dest " .. dest)
        for _, line in ipairs(context.screen.lines) do
          assert_true(line.y1 >= BODY_TOP and line.y2 <= BODY_BOTTOM and line.y2 >= BODY_TOP and line.y1 <= BODY_BOTTOM,
            "shape " .. shape .. " inside the body")
        end
        for _, entry in ipairs(context.screen.texts) do
          if entry.y > 8 and entry.y < HINT_ROW_Y then
            assert_true(entry.y <= BODY_BOTTOM and entry.y - TEXT_HEIGHT + 1 >= BODY_TOP,
              "'" .. entry.text .. "' at y " .. entry.y .. " inside the body")
          end
        end
      end
    end
  end
  -- the rows and the strip never share a line of text
  local_value("S").selected_lfo = 2; redraw()
  local strip_y = pages_lfo().strip_y()
  for n = 1, 3 do
    local row_top = pages_lfo().row_top(n)
    assert_true(strip_y <= row_top or strip_y - TEXT_HEIGHT >= row_top + 11, "the strip clears row " .. n)
  end
  -- cleanup turns a running LFO off
  params:set("lfo_3", 2); cleanup(); assert_equal(params:get("lfo_3"), 1, "cleanup stops LFO 3")
end)

-- The dot swings around the row's middle line (y top + 5) by the depth: at
-- full depth over the whole wave, at 0 (which moves nothing) on the line (#520)
test("the dot's swing follows the depth; at depth 0 it sits on the middle line (#520)", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  params:set("strata_lfo1_dest", 4); params:set("lfo_depth_1", 100); params:set("lfo_1", 2)
  show_page("LFO")
  local top = pages_lfo().row_top(1)
  local function dot_y()
    redraw()
    local rects = lfo_row_drawing(context, 1).rects
    assert_equal(#rects, 1, "one dot")
    return rects[1].y + 1
  end
  context.lfo.tick(lfos[1], 1.0)
  assert_near(dot_y(), top, 0.51, "full depth, raw 1: the top of the wave")
  context.lfo.tick(lfos[1], 0.0)
  assert_near(dot_y(), top + 10, 0.51, "full depth, raw 0: its bottom")
  params:set("lfo_depth_1", 50); context.lfo.tick(lfos[1], 1.0)
  assert_near(dot_y(), top + 10 - 0.75 * 10, 0.51, "50 %: half the swing")
  params:set("lfo_depth_1", 0)
  context.lfo.tick(lfos[1], 0.0)   -- the library sends nothing at depth 0
  assert_near(dot_y(), top + 5, 0.51, "depth 0: on the middle line, whatever the last raw value")
end)

test("LFO ALT+K3 reaches the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("LFO")
  h.assert_drawn_on_next_frame(context, arc_hardware, "LFO page ALT+K3", function() with_alt(function() tap(3) end) end)
  assert_equal(params:string("lfo_1"), "on", "ALT+K3 started LFO 1")
end)

test("the LFO page's layout states cover each LFO, each field, clocked and free", function()
  load_strata()
  local record = local_value("S").registry.pages[local_value("S").constants.UI_PAGES.index.LFO]
  local names = {}
  for _, state in ipairs(record.layout_states or {}) do names[state.name] = true end
  for _, name in ipairs({ "lfo1", "lfo2", "lfo3", "field-dest", "field-shape", "field-mode", "field-rate",
    "field-depth", "field-offset", "field-state", "clocked", "free" }) do
    assert_true(names[name], "a layout state " .. name)
  end
end)

end

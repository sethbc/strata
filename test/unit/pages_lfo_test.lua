-- test/unit/pages_lfo_test.lua
-- The LFO page (lib/pages/lfo.lua): its rows, keys and drawing
-- Run alone: lua test/run.lua pages_lfo

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap = h.tap

test("LFO page: E2 selects, E3 depth in percent, K3 enables, K2 cycles destination", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  enc(2, 1); assert_equal(local_value("selected_lfo"), 2)
  enc(2, 5); assert_equal(local_value("selected_lfo"), 3, "clamped to 3 LFOs")
  enc(2, -1)
  enc(3, 7); assert_equal(params:get("lfo_depth_2"), 7, "E3 steps depth by percent")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "on")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "off")
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 2)
  params:set("strata_lfo2_dest", #local_value("LFO_DESTINATIONS"))
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 1, "K2 wraps to none")
  -- MAIN is untouched by LFO page input
  assert_equal(local_value("selected_voice"), 1)
end)

test("the LFO page redraws on every frame while it is shown, with no clock of its own", function()
  local context = load_strata(); finish_startup(context)
  local baseline = context.clock.pending_count()
  show_page("LFO")
  assert_equal(context.clock.pending_count(), baseline, "no page clock: the frame clock draws it")
  next_frame(context)
  local counter = count_screen_draws()
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 2, "each frame redraws, so the dots move")
  show_page("BUFFER"); next_frame(context)
  counter.screen = 0
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "other pages draw only when asked")
end)

-- The LFO page's waveform, dot and labels for LFO n
local function lfo_row_drawing(context, n)
  local top = 16 + (n - 1) * 15
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
  -- every drawn shape stays inside its row, rows inside y 14-58
  for _, line in ipairs(context.screen.lines) do
    assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "line inside y 14-58")
    assert_true(line.x1 >= 12 and line.x2 <= 75, "waveform inside x 12-75")
  end
  local row = lfo_row_drawing(context, 1)
  assert_true(#row.lines >= 63, "64 px waveform ")
  assert_equal(#row.rects, 1, "one dot for a running LFO")
  -- reset to the floor (phase 0.75) at t 100, so at t 100 the dot is at 0.75
  local dot = row.rects[1]
  assert_near(dot.x + 1, 12 + 0.75 * 63, 0.51, "dot x from the phase since the reset")
  assert_near(dot.y + 1, 16 + 10 - 0.25 * 10, 0.51, "dot y from the last raw value")
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
  assert_true(table.concat(lfo_row_drawing(context, 2).texts, " "):find("off 0%%"), "stopped LFO shows off")
  -- every shape and every destination label keeps the page apart and inside the screen
  for shape = 1, 6 do
    for n = 1, 3 do params:set("lfo_shape_" .. n, shape) end
    for _, dest in ipairs({ 1, 3, 12, 17, 68 }) do
      params:set("strata_lfo2_dest", dest); params:set("lfo_depth_2", 100); redraw()
      assert_screen_layout(context, "LFO shape " .. shape .. ", dest " .. dest)
      for _, line in ipairs(context.screen.lines) do
        assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "shape " .. shape .. " inside rows")
      end
    end
  end
  -- cleanup turns a running LFO off
  params:set("lfo_3", 2); cleanup(); assert_equal(params:get("lfo_3"), 1, "cleanup stops LFO 3")
end)

end

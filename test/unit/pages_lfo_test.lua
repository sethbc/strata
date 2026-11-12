-- test/unit/pages_lfo_test.lua
-- The LFO page (lib/pages/lfo.lua): a window of three of the six LFOs, the
-- selected LFO's field strip, keys, hints, the randomize and its undo, and
-- drawing: the wave, the dot (hollow for a free engine-run LFO), the
-- destination with ~, the depth with R, the rate with max, the window mark
-- Run alone: lua test/run.lua pages_lfo

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, next_frame = h.load_strata, h.local_value, h.next_frame
local finish_startup, text_span, HINT_ROW_Y = h.finish_startup, h.text_span, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap, hint_text, texts_on_row = h.tap, h.hint_text, h.texts_on_row

-- The strip's fields in order (lib/pages/lfo.lua's LFO_FIELDS)
local FIELD = { dest = 1, shape = 2, mode = 3, rate = 4, depth = 5, offset = 6, phase = 7, rate_mod = 8, rate_amt = 9,
  depth_mod = 10, depth_amt = 11, state = 12 }
local FIELD_COUNT = 12

local function lfo_id(n, field) return "strata_lfo" .. n .. (field and ("_" .. field) or "") end
local function pages_lfo() return local_value("S").lib.pages_lfo end
local function lfos() return local_value("S").lib.lfos end

-- Put the strip's cursor on a field (E2 from the first field)
local function strip_field(field)
  enc(2, -20); enc(2, FIELD[field] - 1); redraw()
  assert_equal(local_value("lfo_field"), FIELD[field], "strip cursor on " .. field)
end

-- ALT held around fn (K1 down, fn, K1 up)
local function with_alt(fn)
  key(1, 1); fn(); key(1, 0)
end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error("no option " .. name .. " in " .. param_id)
end

local function destination_index(label)
  for index, destination in ipairs(local_value("LFO_DESTINATIONS")) do
    if destination.label == label then return index end
  end
  error("no LFO destination " .. label)
end

local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- K2 held past the hold time, released (inside with_alt)
local function hold_k2(context)
  key(2, 1); context.clock.run_for(0.5); key(2, 0)
end

-- Select LFO n with K2/K3 from wherever the selection is
local function select_lfo(n)
  for _ = 1, 6 do tap(2) end
  for _ = 2, n do tap(3) end
  assert_equal(local_value("selected_lfo"), n, "LFO " .. n .. " selected")
end

-- The strip's texts, left to right (the line under the selected LFO's row)
local function strip_texts(context)
  return texts_on_row(context, pages_lfo().strip_y())
end

local function bright_strip_text(context)
  for _, entry in ipairs(strip_texts(context)) do
    if entry.level == 15 then return entry.text end
  end
end

-- The row labels L<n> drawn at x 0, top to bottom
local function row_labels(context)
  local labels = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.text:match("^L%d$") then table.insert(labels, entry) end
  end
  table.sort(labels, function(a, b) return a.y < b.y end)
  local names = {}
  for _, entry in ipairs(labels) do table.insert(names, entry.text) end
  return table.concat(names, " ")
end

-- The LFO page's wave, dot and labels for LFO n
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

test("the page shows the selected LFO and its neighbors", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local windows = { [1] = "1-3", [2] = "1-3", [3] = "2-4", [4] = "3-5", [5] = "4-6", [6] = "4-6" }
  for n = 1, 6 do
    select_lfo(n); context.screen.clear(); redraw()
    local first = tonumber(windows[n]:sub(1, 1))
    assert_equal(lfos().window(n), first, "LFO " .. n .. " selected: the window starts at " .. first)
    assert_equal(row_labels(context), "L" .. first .. " L" .. (first + 1) .. " L" .. (first + 2), "rows " .. windows[n])
    local mark
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == windows[n] then mark = entry end
    end
    assert_true(mark ~= nil, "the window's mark " .. windows[n])
    assert_equal(mark.y, pages_lfo().row_top(first) + 11, "on the first row's lower line")
    assert_true(mark.x > pages_lfo().layout.wave_x + pages_lfo().layout.wave_width, "right of the wave")
    assert_equal(pages_lfo().row_top(first + 3), nil, "the rows outside the window are not drawn")
    assert_equal(pages_lfo().strip_y(), pages_lfo().row_top(n) + pages_lfo().layout.strip_baseline, "the strip under it")
    assert_screen_layout(context, "LFO " .. n .. " selected")
  end
end)

test("group starts come from the destinations list", function()
  load_strata()
  assert_equal(table.concat(lfo_dest_group_starts(), " "), "1 2 13 21 29 37 45 53 61 69 76 83 90 97")
  local destinations = local_value("LFO_DESTINATIONS")
  for start, label in pairs({ [69] = "v1 hist", [76] = "v1 vfilt", [83] = "v1 dsend", [90] = "v1 rsend", [97] = "v1 amp" }) do
    assert_equal(destinations[start].label, label, "a registered group starts at voice 1")
  end
  assert_equal(lfo_dest_group_jump(1, -1), 1, "clamped at none")
  assert_equal(lfo_dest_group_jump(5, 1), 13, "next start above")
  assert_equal(lfo_dest_group_jump(5, -1), 2, "last start below")
  assert_equal(lfo_dest_group_jump(68, -1), 61, "from v7 scan back to v7 main")
  assert_equal(lfo_dest_group_jump(103, 1), 103, "clamped at the last destination")
end)

-- #580: the global destinations (3.4's macro 1 .. macro 16) are a group of
-- their own, after every per-voice group
test("a group jump from the last per-voice group lands on the first global destination (#580)", function()
  load_strata({ before_init = function()
    local S = local_value("S")
    S.register_lfo_global_destination("probe 1", "delay_time")
    S.register_lfo_global_destination("probe 2", "delay_mix")
  end })
  assert_equal(table.concat(lfo_dest_group_starts(), " "), "1 2 13 21 29 37 45 53 61 69 76 83 90 97 104")
  assert_equal(lfo_dest_group_jump(97, 1), 104, "from v1 amp to probe 1")
  assert_equal(lfo_dest_group_jump(103, 1), 104, "from v7 amp to probe 1")
  assert_equal(lfo_dest_group_jump(105, -1), 104, "back to the group's start")
  assert_equal(lfo_dest_group_jump(104, -1), 97, "and to the last per-voice group")
  assert_equal(lfo_dest_group_jump(104, 1), 104, "the last group")
end)

test("ALT+E3 lands on each registered group's first voice, both ways (#511)", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local function alt_e3(d) with_alt(function() enc(3, d) end) end
  params:set(lfo_id(1, "dest"), 61)   -- v7 main
  local labels = {}
  for _ = 1, 6 do
    alt_e3(1)
    table.insert(labels, local_value("LFO_DESTINATIONS")[params:get(lfo_id(1, "dest"))].label)
  end
  assert_equal(table.concat(labels, ", "), "v1 hist, v1 vfilt, v1 dsend, v1 rsend, v1 amp, v1 amp", "then clamped")
  params:set(lfo_id(1, "dest"), 103)   -- v7 amp, the last destination
  alt_e3(-1); assert_equal(params:get(lfo_id(1, "dest")), 97, "back to v1 amp")
  alt_e3(-2); assert_equal(params:get(lfo_id(1, "dest")), 83, "two groups back: v1 dsend")
  params:set(lfo_id(1, "dest"), 70)   -- v2 hist
  alt_e3(-1); assert_equal(params:get(lfo_id(1, "dest")), 69, "inside a group: back to its start")
end)

test("E2 moves along the strip and E3 edits each field both ways", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  assert_equal(local_value("lfo_field"), FIELD.dest, "the strip starts on the destination")
  enc(3, 1); assert_equal(params:get(lfo_id(1, "dest")), 2)
  enc(3, -1); enc(3, -1); assert_equal(params:get(lfo_id(1, "dest")), 1, "clamped at none, no wrap")
  enc(2, -1); assert_equal(local_value("lfo_field"), FIELD.dest, "E2 stops at the first field")
  strip_field("shape"); enc(3, 1); assert_equal(params:string(lfo_id(1, "shape")), "tri", "E3 on shape")
  enc(3, -1); assert_equal(params:string(lfo_id(1, "shape")), "sine")
  strip_field("mode"); enc(3, 1); assert_equal(params:string(lfo_id(1, "mode")), "clocked", "E3 on mode")
  strip_field("rate")
  local division = params:get(lfo_id(1, "division"))
  enc(3, 1); assert_equal(params:get(lfo_id(1, "division")), division + 1, "clocked: E3 steps the division")
  strip_field("mode"); enc(3, -1); strip_field("rate")
  local rate = params:get(lfo_id(1, "rate"))
  enc(3, 1); assert_true(params:get(lfo_id(1, "rate")) > rate, "free: E3 raises the rate")
  enc(3, -1); assert_near(params:get(lfo_id(1, "rate")), rate, 1e-6, "and lowers it")
  strip_field("depth"); enc(3, 5); assert_equal(params:get(lfo_id(1, "depth")), 30, "E3 on depth, in percent")
  strip_field("offset"); enc(3, -3); assert_equal(params:get(lfo_id(1, "offset")), -3, "E3 on offset")
  strip_field("phase"); enc(3, 4); assert_equal(params:get(lfo_id(1, "phase")), 4, "E3 on phase")
  strip_field("rate_amt"); enc(3, 10); assert_equal(params:get(lfo_id(1, "rate_mod_amt")), 10, "E3 on rate amt")
  strip_field("depth_amt"); enc(3, -10); assert_equal(params:get(lfo_id(1, "depth_mod_amt")), -10, "E3 on depth amt")
  strip_field("state"); enc(3, 1); assert_equal(params:get(lfo_id(1)), 1, "E3 on on/off")
  enc(3, -1); assert_equal(params:get(lfo_id(1)), 0)
  enc(2, 1); assert_equal(local_value("lfo_field"), FIELD.state, "E2 stops at the last field")
  -- LFO 3's mod sources: none, L1, L2
  select_lfo(3); strip_field("rate_mod")
  enc(3, 1); assert_equal(params:string(lfo_id(3, "rate_mod")), "L1", "E3 on rate mod")
  enc(3, 5); assert_equal(params:string(lfo_id(3, "rate_mod")), "L2", "a lower-numbered LFO only")
  strip_field("depth_mod"); enc(3, 2); assert_equal(params:string(lfo_id(3, "depth_mod")), "L2", "E3 on depth mod")
  assert_equal(local_value("selected_voice"), 1, "MAIN's voice is untouched")
end)

test("the offset and the mod amounts hold at their center detent", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  for field, id in pairs({ offset = lfo_id(1, "offset"), rate_amt = lfo_id(1, "rate_mod_amt"),
    depth_amt = lfo_id(1, "depth_mod_amt") }) do
    strip_field(field)
    params:set(id, 2)
    enc(3, -5); assert_equal(params:get(id), 0, field .. ": an accelerated turn lands on 0")
    enc(3, -1); assert_equal(params:get(id), 0, field .. ": and holds there")
  end
end)

test("the strip shows as many fields as fit and keeps the cursor's in view", function()
  local context = load_strata(); finish_startup(context)
  params:set(lfo_id(1, "dest"), destination_index("filt freq"))
  show_page("LFO")
  local texts = strip_texts(context)
  assert_equal(texts[1].text, "filt freq", "the destination first")
  assert_equal(texts[1].x, 0)
  assert_equal(texts[1].level, 15, "the cursor's field bright")
  assert_equal(texts[2].text, "sine"); assert_equal(texts[2].level, 4, "the others dim")
  assert_equal(texts[#texts].text, ">", "more fields to the right")
  local _, right = text_span(texts[#texts])
  assert_true(right <= 128, "the marker ends inside the screen")
  strip_field("state")
  texts = strip_texts(context)
  assert_equal(texts[1].text, "<", "fields off to the left")
  assert_equal(texts[#texts].text, "off", "on/off drawn last")
  params:set(lfo_id(1, "offset"), 20); params:set(lfo_id(1, "depth"), 70); params:set(lfo_id(1, "phase"), 30)
  params:set(lfo_id(1, "rate_mod_amt"), -40); params:set(lfo_id(1, "depth_mod_amt"), 15)
  local expected = { "filt freq", "sine", "free", "0.25Hz", "70%", "+20%", "ph 30%", "rmod none", "ramt -40%",
    "dmod none", "damt +15%", "off" }
  for field = 1, FIELD_COUNT do
    enc(2, -20); enc(2, field - 1); redraw()
    assert_equal(bright_strip_text(context), expected[field], "field " .. field .. " shown bright")
    assert_screen_layout(context, "LFO strip field " .. field)
  end
  -- a clocked rate shows its division
  params:set(lfo_id(1, "mode"), 2); params:set(lfo_id(1, "division"), 5)
  strip_field("rate")
  assert_equal(bright_strip_text(context), "1/3", "the clocked division")
  -- LFO 2's mod sources
  select_lfo(2)
  params:set(lfo_id(2, "depth_mod"), 2); strip_field("depth_mod")
  assert_equal(bright_strip_text(context), "dmod L1")
end)

test("the destination shows ~ in the engine, the rate max above 10 Hz in Lua and the depth R when routed", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local function row_has(n, text)
    context.screen.clear(); redraw()
    return table.concat(lfo_row_drawing(context, n).texts, "|"):find(text, 1, true) ~= nil
  end
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch"))
  assert_true(row_has(1, "v3 pitch~"), "an engine-run destination's ~")
  assert_equal(bright_strip_text(context), "v3 pitch~", "in the strip too")
  params:set(lfo_id(1, "dest"), destination_index("rev mix"))
  assert_true(row_has(1, "rev mix") and not row_has(1, "~"), "a Lua destination has none")
  params:set(lfo_id(1, "rate"), 20); params:set(lfo_id(1), 1); lfo_step(context)
  strip_field("rate")
  assert_equal(bright_strip_text(context), "20Hz max", "a Lua-run LFO above 10 Hz")
  params:set(lfo_id(1, "dest"), destination_index("v3 pitch"))
  redraw(); assert_equal(bright_strip_text(context), "20Hz", "in the engine it plays at 20 Hz")
  params:set(lfo_id(1, "rate"), 8); redraw()
  params:set(lfo_id(1, "dest"), destination_index("rev mix")); redraw()
  assert_equal(bright_strip_text(context), "8Hz", "below 10 Hz no mark")
  -- S.lib.matrix (package 1h) routing an LFO marks its depth
  local S = local_value("S")
  assert_true(row_has(2, "off 25%") and not row_has(2, " R"), "no matrix: no mark")
  local asked = {}
  S.lib.matrix = { uses_source = function(key) table.insert(asked, key); return key == "lfo2" end }
  local ok, problem = pcall(function()
    assert_true(row_has(2, "off 25% R"), "LFO 2 is routed")
    assert_true(row_has(1, "on 25%") and not row_has(1, " R"), "LFO 1 is not")
    assert_true(#asked >= 2, "the page asked the matrix")
    assert_screen_layout(context, "a routed LFO")
  end)
  S.lib.matrix = nil
  if not ok then error(problem, 0) end
end)

test("ALT+E3 on the destination jumps a group; elsewhere it is fine on the rate and whole steps on a percent", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local function alt_e3(d) with_alt(function() enc(3, d) end) end
  alt_e3(1); assert_equal(params:get(lfo_id(1, "dest")), 2, "none to the first global")
  alt_e3(1); assert_equal(params:get(lfo_id(1, "dest")), 13, "to v1 main")
  alt_e3(1); assert_equal(params:get(lfo_id(1, "dest")), 21, "to v2 main")
  params:set(lfo_id(1, "dest"), 15)
  alt_e3(-1); assert_equal(params:get(lfo_id(1, "dest")), 13, "back to its group's start")
  alt_e3(-1); assert_equal(params:get(lfo_id(1, "dest")), 2, "then the globals")
  strip_field("rate")
  params:set(lfo_id(1, "rate"), 1)
  local rate = params:get(lfo_id(1, "rate"))
  enc(3, 1); local coarse = params:get(lfo_id(1, "rate")) - rate
  enc(3, -1)
  alt_e3(1); local fine = params:get(lfo_id(1, "rate")) - rate
  assert_true(fine > 0 and fine < coarse, "ALT+E3 moves the rate finer")
  strip_field("depth"); alt_e3(2)
  assert_equal(params:get(lfo_id(1, "depth")), 27, "a percent keeps whole steps")
end)

test("K2 and K3 select the LFO; a new window forgets the depth rings' ticks, a new LFO ring 4's", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("LFO")
  tap(2); assert_equal(S.selected_lfo, 1, "K2 stops at LFO 1")
  S.arc_ticks["lfo:4"] = 15; S.arc_ticks["lfo:1"] = 5
  tap(3); assert_equal(S.selected_lfo, 2, "K3: the next LFO")
  assert_equal(S.arc_ticks["lfo:4"], nil, "ring 4's ticks forgotten")
  assert_equal(S.arc_ticks["lfo:1"], 5, "the same window keeps the depth rings' ticks")
  tap(3); assert_equal(S.selected_lfo, 3)
  assert_equal(S.arc_ticks["lfo:1"], nil, "a new window forgets them")
  for _ = 1, 5 do tap(3) end
  assert_equal(S.selected_lfo, 6, "K3 stops at the last LFO")
  S.arc_ticks["lfo:4"] = 15
  tap(3); assert_equal(S.arc_ticks["lfo:4"], 15, "no change, nothing forgotten")
  tap(2); assert_equal(S.selected_lfo, 5, "K2: the previous LFO")
  strip_field("depth"); enc(3, 3)
  assert_equal(params:get(lfo_id(5, "depth")), 28, "the strip edits the selected LFO")
  assert_equal(params:get(lfo_id(1, "depth")), 25, "and leaves the others")
  for n = 1, 6 do assert_equal(params:get(lfo_id(n)), 0, "K2/K3 turn nothing on") end
end)

test("ALT+K2 held resets the field; ALT+K3 and the arc button turn the LFO on and off", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local resets = { { "depth", lfo_id(1, "depth"), 70, 25 }, { "dest", lfo_id(1, "dest"), 30, 1 },
    { "rate", lfo_id(1, "rate"), 3, 0.25 }, { "offset", lfo_id(1, "offset"), -12, 0 },
    { "phase", lfo_id(1, "phase"), 40, 0 }, { "rate_amt", lfo_id(1, "rate_mod_amt"), 30, 0 } }
  for _, case in ipairs(resets) do
    strip_field(case[1]); params:set(case[2], case[3])
    with_alt(function() hold_k2(context) end)
    assert_near(params:get(case[2]), case[4], 1e-9, case[1] .. " back to its default")
  end
  strip_field("state"); params:set(lfo_id(1), 1)
  with_alt(function() hold_k2(context) end)
  assert_equal(params:get(lfo_id(1)), 0, "on/off back to off")
  with_alt(function() tap(3) end)
  assert_equal(params:get(lfo_id(1)), 1, "ALT+K3 turns the LFO on")
  with_alt(function() tap(3) end)
  assert_equal(params:get(lfo_id(1)), 0, "and off")
  context.arc.plug(1)
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(params:get(lfo_id(1)), 1, "the arc button turns the selected LFO on")
  select_lfo(5); context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(params:get(lfo_id(5)), 1, "the selected one")
end)

test("LFO hints", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  local labels = { "dest", "shape", "mode", "rate", "depth", "offset", "phase", "rate mod", "rate amt", "depth mod",
    "depth amt", "on/off" }
  for field = 1, FIELD_COUNT do
    enc(2, -20); enc(2, field - 1); redraw()
    assert_equal(hint_text(context), "K2/K3:lfo E3:" .. labels[field])
  end
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:on")
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:rand K3:off")
  key(1, 0); enc(2, -20); key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:off E3:group", "the destination's ALT+E3 group jump")
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
  params:set(lfo_id(5), 1); next_frame(context)
  counter.screen = 0
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 2, "an LFO runs (outside the window too): each frame redraws")
  params:set(lfo_id(5), 0); next_frame(context)
  assert_equal(counter.screen, 3, "turning it off draws once")
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 3, "then the page is idle again")
  params:set(lfo_id(3), 1); show_page("BUFFER"); next_frame(context)
  counter.screen = 0
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "other pages draw only when asked, LFOs running or not")
end)

test("LFO page rows: wave, dot at the LFO's phase and value, labels, a hollow dot for a free engine LFO", function()
  local context = load_strata(); finish_startup(context)
  local layout = pages_lfo().layout
  params:set(lfo_id(1, "dest"), destination_index("filt freq")); params:set(lfo_id(1, "depth"), 50)
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "up"))
  params:set(lfo_id(1, "rate"), 0.003); params:set(lfo_id(1, "phase"), 25); params:set(lfo_id(1), 1)
  lfo_step(context)
  show_page("LFO")
  for n = 1, 3 do
    local row = lfo_row_drawing(context, n)
    assert_true(table.concat(row.texts, " "):find("L" .. n, 1, true), "row " .. n .. " labeled L" .. n)
    assert_true(#row.lines >= layout.wave_width - 1, "row " .. n .. " draws its wave")
  end
  for _, line in ipairs(context.screen.lines) do
    assert_true(line.y1 >= BODY_TOP and line.y2 <= BODY_BOTTOM, "lines inside the body")
    assert_true(line.x1 >= layout.wave_x and line.x2 <= layout.wave_x + layout.wave_width - 1, "the wave's x")
  end
  local row = lfo_row_drawing(context, 1)
  assert_equal(#row.rects, 1, "one dot for a running LFO")
  local dot = row.rects[1]
  local top = pages_lfo().row_top(1)
  assert_near(dot.x + 1, layout.wave_x + 0.25 * (layout.wave_width - 1), 0.51, "dot x from the phase")
  -- up at 0.25: u 0.25, a quarter below the middle at full depth, half that at 50 %
  assert_near(dot.y + 1, top + 10 - (0.5 - 0.25 * 0.5) * 10, 0.51, "dot y from the value and the depth")
  assert_true(dot.filled, "a Lua-run LFO's dot is filled")
  assert_true(table.concat(row.texts, " "):find("filt freq", 1, true), "destination label")
  assert_true(table.concat(row.texts, " "):find("on 50%", 1, true), "state and depth")
  assert_equal(#lfo_row_drawing(context, 2).rects, 0, "no dot for a stopped LFO")
  assert_true(table.concat(lfo_row_drawing(context, 2).texts, " "):find("off 25%", 1, true), "stopped LFO shows off")
  -- a free engine-run LFO's dot is an estimate: hollow; a clocked one's is exact
  params:set(lfo_id(1, "dest"), destination_index("v2 size")); lfo_step(context); redraw()
  local hollow = lfo_row_drawing(context, 1).rects[1]
  assert_true(hollow and hollow.filled == false, "a free engine-run LFO: a hollow dot")
  assert_equal(hollow.w, 3); assert_equal(hollow.h, 3)
  params:set(lfo_id(1, "mode"), 2); lfo_step(context); redraw()
  assert_true(lfo_row_drawing(context, 1).rects[1].filled, "a clocked engine-run LFO: filled")
  -- every shape and every destination label, under each selected LFO, keeps
  -- the page apart and inside the screen
  show_page("LFO")
  for selected = 1, 6 do
    select_lfo(selected)
    for shape = 1, 8 do
      for n = 1, 6 do params:set(lfo_id(n, "shape"), shape) end
      for _, dest in ipairs({ 1, 3, 12, 17, 68, 103 }) do
        params:set(lfo_id(selected, "dest"), dest); params:set(lfo_id(selected, "depth"), 100); redraw()
        assert_screen_layout(context, "LFO " .. selected .. " selected, shape " .. shape .. ", dest " .. dest)
        for _, line in ipairs(context.screen.lines) do
          assert_true(line.y1 >= BODY_TOP and line.y2 <= BODY_BOTTOM, "shape " .. shape .. " inside the body")
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
end)

-- The dot swings around the row's middle line (y top + 5) by the depth the
-- LFO plays: at full depth over the whole wave, at 0 on the line (#520)
test("the dot's swing follows the depth; at depth 0 it sits on the middle line (#520)", function()
  local context = load_strata(); finish_startup(context)
  params:set(lfo_id(1, "dest"), destination_index("filt freq")); params:set(lfo_id(1, "depth"), 100)
  params:set(lfo_id(1, "shape"), option_index(lfo_id(1, "shape"), "square"))
  params:set(lfo_id(1, "rate"), 0.003); params:set(lfo_id(1), 1)
  show_page("LFO")
  local top = pages_lfo().row_top(1)
  local function dot_y()
    lfo_step(context); redraw()
    local rects = lfo_row_drawing(context, 1).rects
    assert_equal(#rects, 1, "one dot")
    return rects[1].y + 1
  end
  assert_near(dot_y(), top, 0.51, "full depth, value 1: the top of the wave")
  params:set(lfo_id(1, "phase"), 50)
  assert_near(dot_y(), top + 10, 0.51, "full depth, value -1: its bottom")
  params:set(lfo_id(1, "depth"), 50); params:set(lfo_id(1, "phase"), 0)
  assert_near(dot_y(), top + 10 - 0.75 * 10, 0.51, "50 %: half the swing")
  params:set(lfo_id(1, "depth"), 0)
  assert_near(dot_y(), top + 5, 0.51, "depth 0: on the middle line")
end)

test("LFO rows keep a blank pixel row between each destination and the row above", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  for n = 1, 6 do params:set(lfo_id(n, "dest"), destination_index("density")) end
  local S = local_value("S")
  if not S.lib.matrix then S.lib.matrix = { uses_source = function() return true end } end
  local ok, problem = pcall(function()
    for selected = 1, 6 do
      select_lfo(selected)
      context.screen.clear(); redraw()
      local column = {}
      for _, entry in ipairs(context.screen.texts) do
        if entry.align == "right" and entry.x == 127 and entry.y > 8 and entry.y < HINT_ROW_Y then
          table.insert(column, entry)
        end
      end
      table.sort(column, function(a, b) return a.y < b.y end)
      for index = 2, #column do
        local upper, lower = column[index - 1], column[index]
        assert_true(lower.y - upper.y >= TEXT_HEIGHT, string.format("LFO %d selected: '%s' at y %d is %d px under '%s'",
          selected, lower.text, lower.y, lower.y - upper.y, upper.text))
      end
      assert_true(column[#column].y <= HINT_ROW_Y - TEXT_HEIGHT, "the last row clears the hint row")
      assert_screen_layout(context, "LFO " .. selected .. " selected, density, routed")
    end
  end)
  S.lib.matrix = nil
  if not ok then error(problem, 0) end
end)

test("LFO ALT+K3 reaches the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("LFO")
  h.assert_drawn_on_next_frame(context, arc_hardware, "LFO page ALT+K3", function() with_alt(function() tap(3) end) end)
  assert_equal(params:get(lfo_id(1)), 1, "ALT+K3 started LFO 1")
end)

test("the LFO page's layout states cover each field on LFOs 1 and 6, each window, engine-run, modulated and max", function()
  load_strata()
  local record = local_value("S").registry.pages[local_value("S").constants.UI_PAGES.index.LFO]
  local names = {}
  for _, state in ipairs(record.layout_states or {}) do names[state.name] = true end
  local wanted = { "window 1-3", "window 2-4", "window 3-5", "window 4-6", "engine-run and modulated", "rate max",
    "clocked", "ALT+K2 held past the hold time" }
  for _, n in ipairs({ 1, 6 }) do
    for _, field in ipairs({ "dest", "shape", "mode", "rate", "depth", "offset", "phase", "rate mod", "rate amt",
      "depth mod", "depth amt", "on/off" }) do
      table.insert(wanted, "lfo" .. n .. " " .. field)
    end
  end
  for _, name in ipairs(wanted) do assert_true(names[name], "a layout state " .. name) end
end)

-- #557: ALT+K2 randomizes the selected LFO's shape, rate or division and
-- phase; held, it resets the field
local KEPT = { "dest", "mode", "depth", "offset", "rate_mod", "rate_mod_amt", "depth_mod", "depth_mod_amt" }

local function lfo_snapshot(n)
  local out = { [lfo_id(n)] = params:get(lfo_id(n)) }
  for _, field in ipairs({ "dest", "mode", "depth", "offset", "rate_mod", "rate_mod_amt", "depth_mod", "depth_mod_amt",
    "shape", "rate", "division", "phase" }) do
    out[lfo_id(n, field)] = params:get(lfo_id(n, field))
  end
  return out
end

test("ALT+K2 randomizes the selected LFO's shape, rate or division and phase, and nothing else", function()
  for _, mode in ipairs({ "free", "clocked" }) do
    local context = load_strata(); finish_startup(context)
    show_page("LFO")
    select_lfo(4)
    params:set(lfo_id(4, "mode"), option_index(lfo_id(4, "mode"), mode))
    params:set(lfo_id(4, "dest"), 5); params:set(lfo_id(4, "depth"), 60); params:set(lfo_id(4, "offset"), 10)
    params:set(lfo_id(4, "rate_mod"), 2); params:set(lfo_id(4, "rate_mod_amt"), 30)
    params:set(lfo_id(4, "depth_mod"), 3); params:set(lfo_id(4, "depth_mod_amt"), -20)
    params:set(lfo_id(4), 1)
    local before = lfo_snapshot(4)
    local others = {}
    for n = 1, 6 do if n ~= 4 then others[n] = lfo_snapshot(n) end end
    local shapes, rates, phases = {}, {}, {}
    math.randomseed(5)
    for _ = 1, 20 do
      with_alt(function() tap(2) end)
      local now = lfo_snapshot(4)
      local shape = now[lfo_id(4, "shape")]
      assert_true(shape >= 1 and shape <= 8 and shape % 1 == 0, mode .. ": a shape 1-8")
      shapes[shape] = true
      local phase = now[lfo_id(4, "phase")]
      assert_true(phase >= 0 and phase <= 100, mode .. ": a phase 0-100")
      phases[phase] = true
      if mode == "free" then
        local rate = now[lfo_id(4, "rate")]
        assert_true(rate >= 0.05 - 1e-9 and rate <= 10 + 1e-9, mode .. ": a rate 0.05-10 Hz (" .. rate .. ")")
        assert_equal(now[lfo_id(4, "division")], before[lfo_id(4, "division")], "the division is kept in free mode")
        rates[rate] = true
      else
        local division = now[lfo_id(4, "division")]
        assert_true(division >= 1 and division <= 22, "any division")
        assert_near(now[lfo_id(4, "rate")], before[lfo_id(4, "rate")], 1e-9, "the rate is kept in clocked mode")
        rates[division] = true
      end
      for _, field in ipairs(KEPT) do
        assert_equal(now[lfo_id(4, field)], before[lfo_id(4, field)], mode .. ": " .. field .. " kept")
      end
      assert_equal(now[lfo_id(4)], 1, mode .. ": still running")
      for n, snapshot in pairs(others) do
        for id, value in pairs(snapshot) do assert_equal(params:get(id), value, mode .. ": LFO " .. n .. " untouched: " .. id) end
      end
      with_alt(function() tap(2) end)  -- undo
      assert_equal(params:get(lfo_id(4, "shape")), before[lfo_id(4, "shape")], mode .. ": undo restores the shape")
      assert_equal(params:get(lfo_id(4, "phase")), before[lfo_id(4, "phase")], mode .. ": and the phase")
    end
    local function count(set) local n = 0; for _ in pairs(set) do n = n + 1 end; return n end
    assert_true(count(shapes) >= 3, mode .. ": the shape varies")
    assert_true(count(rates) >= 3, mode .. ": the rate varies")
    assert_true(count(phases) >= 3, mode .. ": the phase varies")
  end
  -- the free rate is even in octaves: about half the draws below 0.707 Hz
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  math.randomseed(21)
  local below = 0
  for _ = 1, 200 do
    with_alt(function() tap(2) end)
    if params:get(lfo_id(1, "rate")) < math.sqrt(0.05 * 10) then below = below + 1 end
    with_alt(function() tap(2) end)
  end
  assert_true(below > 70 and below < 130, "even in octaves (" .. below .. " of 200 below the middle octave)")
end)

test("each LFO and mode holds its own undo", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  math.randomseed(11)
  with_alt(function() tap(2) end)  -- randomize LFO 1
  local randomized = lfo_snapshot(1)
  select_lfo(6)
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:on E3:group", "LFO 1's undo is not LFO 6's")
  tap(2); key(1, 0)
  for id, value in pairs(randomized) do assert_equal(params:get(id), value, "LFO 1 keeps its randomized " .. id) end
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:undo K3:on E3:group", "LFO 6 now holds the undo")
  key(1, 0)
  params:set(lfo_id(6, "mode"), option_index(lfo_id(6, "mode"), "clocked"))
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:on E3:group", "clocked mode: the free rate's undo is not shown")
  key(1, 0)
  local spec = local_value("S").registry.pages[local_value("S").constants.UI_PAGES.index.LFO].randomize_section()
  assert_equal(spec.section, "lfo 6 clocked", "the section names the LFO and its mode")
  assert_equal(spec.voice, nil, "no voice")
end)

-- K1 let go before K2: the release still randomizes or resets, so the hint
-- row keeps K2's release hint, alone, until K2 comes up
test("K2's release hint stays after K1 comes up first (#557)", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  context.screen.clear(); redraw()
  local plain = hint_text(context)
  key(1, 1); key(2, 1); key(1, 0)
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:rand", "K1 up, K2 down: the quick release's hint")
  context.clock.run_for(0.5); context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:reset", "held past the hold time: letting go resets")
  key(2, 0); context.screen.clear(); redraw()
  assert_equal(hint_text(context), plain, "K2 up: the plain hints")
end)

end

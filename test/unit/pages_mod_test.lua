-- test/unit/pages_mod_test.lua
-- The MOD page (lib/pages/mod.lua, 3.4, design §10 and §10.2): the list of
-- sections and their rows, drawn from the modulation sources' records, the
-- macro bank, the target view, the gesture and LFO rows, the matrix rows and
-- the routing view, learn, the section randomize and its undo, the hints
-- Run alone: lua test/run.lua pages_mod

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text, assert_screen_layout, text_span = h.show_page, h.hint_text, h.assert_screen_layout, h.text_span
local tap, screen_shows = h.tap, h.screen_shows

-- The list view's rows: five from y 18, 8 px apart; section labels at x 0
-- (level 2), a row's label at x 6, its text at x 24, its value right at 124
local LIST_YS = { 18, 26, 34, 42, 50 }
local ROW_LABEL_X = 6

local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MOD")
  return context, S
end

-- Put the list cursor on a row by its id (the page's own placing)
local function place(S, id)
  assert_true(S.lib.pages_mod.place(id), "MOD has a row " .. id)
  redraw()
end

-- The texts of row y from x 1 on: the left-aligned ones joined by a space,
-- then two spaces and the right-aligned ones joined as they touch
-- ("R3 L2>v3 pitch~  +40%", "1 v3 pitch  20>90%")
local function row_text(context, y, from_x)
  local left, right = {}, {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == y and entry.x >= (from_x or 1) then
      table.insert(entry.align == "right" and right or left, entry)
    end
  end
  local function by_x(a, b) return select(1, text_span(a)) < select(1, text_span(b)) end
  table.sort(left, by_x); table.sort(right, by_x)
  local left_text, right_text = {}, {}
  for _, entry in ipairs(left) do left_text[#left_text + 1] = entry.text end
  for _, entry in ipairs(right) do right_text[#right_text + 1] = entry.text end
  local text = table.concat(left_text, " ")
  if #right_text > 0 then text = text .. (text ~= "" and "  " or "") .. table.concat(right_text) end
  return text
end

-- The list row whose label (at x 6) reads `label`: its y and level, or nil
local function list_row(context, label)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == ROW_LABEL_X and entry.text == label and entry.y >= 18 and entry.y <= 50 then return entry end
  end
end

-- The label of the row under the cursor: the brightest at x 6 (15, or 10
-- on a dim row: a routing that is off or incomplete)
local function cursor_label(context)
  local best
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == ROW_LABEL_X and entry.level >= 10 and entry.y >= 18 and entry.y <= 50
        and (best == nil or entry.level > best.level) then
      best = entry
    end
  end
  return best and best.text
end

-- The section labels drawn (x 0, level 2, inside the list)
local function section_labels(context)
  local labels = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.level == 2 and entry.y >= 18 and entry.y <= 50 then labels[#labels + 1] = entry.text end
  end
  return labels
end

local function alt_k2_quick() key(1, 1); key(2, 1); key(2, 0); key(1, 0) end

local function alt_k2_held(context)
  key(1, 1); key(2, 1)
  context.clock.run_for(local_value("S").constants.ALT_HOLD_SECONDS)
end

-- A touch a surface makes on another page: VOICE's E3 on one of a voice's
-- params (the voice selected, the cursor put on the param's row)
local function voice_e3(S, voice_idx, param_id, d)
  show_page("VOICE")
  S.lib.ui_keys.select_voice_by(voice_idx - S.selected_voice)
  local index = S.lib.pages_voice.row_of(param_id)
  assert_true(index, "VOICE has a row " .. param_id)
  S.lib.pages_voice.place_cursor(index)
  enc(3, d)
end

-- The header's text at x 40, a flash or a notice (nil: the page dots)
local function header_notice(context)
  context.screen.clear(); redraw()
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == 8 and entry.x == 40 then return entry.text end
  end
end

-- Every param's value, joined (what a press that changes nothing leaves)
local function param_snapshot()
  local ids = {}
  for id in pairs(params.lookup) do ids[#ids + 1] = id end
  table.sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do parts[#parts + 1] = id .. "=" .. tostring(params:get(id)) end
  return table.concat(parts, ";")
end

test("MOD is the sixth page and the header shows nine dots", function()
  local context, S = loaded()
  local C = S.constants
  assert_equal(table.concat(C.UI_PAGES, " "), "MAIN VOICE SEQ FX LFO MOD BUFFER SCENES SETUP")
  assert_equal(C.UI_PAGES.index.MOD, 6, "MOD after LFO")
  assert_equal(C.NUM_UI_PAGES, 9)
  assert_equal(S.registry.pages[C.UI_PAGES.index.MOD].name, "MOD")
  redraw()
  assert_equal(context.screen.texts[1].text, "MOD", "the title at 0,8")
  local dots = {}
  for _, rect in ipairs(context.screen.rects) do
    if rect.y + rect.h <= 9 and rect.w == 2 and rect.h == 2 then dots[#dots + 1] = rect end
  end
  table.sort(dots, function(a, b) return a.x < b.x end)
  assert_equal(#dots, 9, "nine page dots")
  assert_equal(dots[1].x, 36, "from x 36")
  assert_equal(dots[9].x, 68, "4 px apart, the last at x 68")
  assert_equal(dots[6].level, 15, "the sixth bright")
  assert_screen_layout(context, "MOD as loaded")
end)

test("the list draws each section's sources from their records, in section order", function()
  local context, S = loaded()
  -- a record's describe is what its row shows
  local record = S.lib.mod_sources.get("gesture2")
  local real_describe = record.describe
  record.describe = function() return "probe text" end
  local labels, sections, shown = {}, {}, {}
  enc(2, -200)
  for _ = 1, 80 do
    redraw()
    labels[#labels + 1] = cursor_label(context)
    for _, section in ipairs(section_labels(context)) do
      if not shown[section] then shown[section] = true; sections[#sections + 1] = section end
    end
    if cursor_label(context) == "G2" then
      assert_equal(row_text(context, list_row(context, "G2").y, ROW_LABEL_X), "G2 probe text", "G2's row from its record")
    end
    enc(2, 1)
  end
  record.describe = real_describe
  -- consecutive duplicates (the cursor at the last row) dropped
  local walk = {}
  for _, label in ipairs(labels) do if walk[#walk] ~= label then walk[#walk + 1] = label end end
  assert_equal(table.concat(walk, " "), "bank M1 M2 M3 M4 A B C D morph y on depth rate pitch pos size cutoff amp "
    .. "G1 G2 G3 G4 L1 L2 L3 L4 L5 L6 R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15 R16 IN",
    "the rows in section order")
  assert_equal(table.concat(sections, " "), "macros morph scatter gestures lfos matrix audio",
    "MOD_PAGE.sections, then the input level's own section")
  assert_equal(table.concat(S.MOD_PAGE.sections, " "), "macros morph scatter gestures lfos matrix")
  -- an LFO row is its record's describe: destination, depth, its inputs
  params:set("strata_lfo2_dest", 1)
  S.lib.pages_mod.place("source:lfo2"); redraw()
  assert_equal(row_text(context, list_row(context, "L2").y, ROW_LABEL_X), "L2 " .. S.lib.lfos.describe(2))
end)

test("a section registered by a test shows after the matrix, read-only without a row", function()
  local context, S = loaded()
  S.register_mod_source({ key = "probe", name = "PRB", section = "probes", range = { 0, 1 },
    value = function() return 0.5 end, describe = function() return "42 units" end })
  enc(2, 200); redraw()
  assert_equal(cursor_label(context), "PRB", "the new section's row is the last")
  local labels = section_labels(context)
  assert_equal(labels[#labels], "probes", "its section label after the others")
  assert_equal(row_text(context, list_row(context, "PRB").y, ROW_LABEL_X), "PRB 42 units", "drawn from its record alone")
  assert_equal(hint_text(context), "", "no row: no hint")
  local before = param_snapshot()
  enc(3, 5); tap(3); key(1, 1); tap(3); key(1, 0)
  assert_equal(param_snapshot(), before, "E3, K3 and ALT+K3 do nothing")
  -- the matrix comes before it
  enc(2, -1); redraw()
  assert_equal(cursor_label(context), "IN")
  enc(2, -1); redraw()
  assert_equal(cursor_label(context), "R16")
  assert_screen_layout(context, "a registered section")
end)

test("the bank row and ALT+E2 change the shown bank for every surface", function()
  local context, S = loaded()
  local macros = S.lib.macros
  local device = context.arc.plug(1)
  place(S, "bank")
  assert_equal(row_text(context, list_row(context, "bank").y, ROW_LABEL_X), "bank  1  M1-M4")
  enc(3, 1); redraw()
  assert_equal(macros.bank(), 2, "E3 the bank")
  assert_equal(row_text(context, list_row(context, "bank").y, ROW_LABEL_X), "bank  2  M5-M8")
  assert_true(list_row(context, "M5") and list_row(context, "M7") and not list_row(context, "M1"), "the rows follow")
  enc(3, 10); assert_equal(macros.bank(), 4, "E3 stops at bank 4")
  tap(3); assert_equal(macros.bank(), 1, "K3 the next bank, 4 wrapping to 1")
  tap(3); assert_equal(macros.bank(), 2)
  -- ALT+E2 on a macro row: the same row of the next bank
  place(S, "source:macro6")
  key(1, 1); enc(2, 1); key(1, 0); redraw()
  assert_equal(macros.bank(), 3, "ALT+E2 the next bank")
  assert_equal(cursor_label(context), "M10", "the same row of it")
  key(1, 1); enc(2, 1); enc(2, 1); key(1, 0); redraw()
  assert_equal(macros.bank(), 1, "bank 4 wraps to 1")
  assert_equal(cursor_label(context), "M2")
  key(1, 1); enc(2, -1); key(1, 0)
  assert_equal(macros.bank(), 4, "and back from 1 to 4")
  -- every surface: the arc's rings and another surface's change
  context.arc.turn(1, 1, 100)
  assert_true(params:get("macro_13") > 0, "arc ring 1 is bank 4's first macro")
  assert_equal(params:get("macro_1"), 0)
  macros.set_bank(3); redraw()
  assert_equal(cursor_label(context), "M10", "a bank set elsewhere moves the rows")
  assert_true(device ~= nil)
end)

test("K3 on a macro row opens its targets; E3 edits the cursor's column; K2 goes back", function()
  local context, S = loaded()
  local macros = S.lib.macros
  local ids = macros.target_ids()
  place(S, "source:macro1")
  assert_equal(hint_text(context), "K3:targets E3:value")
  tap(3); redraw()
  assert_equal(S.mod_page.view, "targets")
  assert_equal(row_text(context, 16, 0), "M1 targets  0%", "the title and the macro's value")
  assert_equal(row_text(context, 24, 0), "1 -", "an empty row")
  assert_equal(hint_text(context), "K2:back K3:col E3:target")
  -- the target column steps through target_ids()
  enc(3, 1)
  assert_equal(S.macros[1].targets[1].id, ids[1], "E3 +1: the first target")
  enc(3, 2)
  assert_equal(S.macros[1].targets[1].id, ids[3], "then the third")
  enc(3, -3)
  assert_equal(S.macros[1].targets[1].id, "", "back to none")
  macros.set_target(1, 1, "v3_grain_pitch", 0, 1); redraw()
  assert_equal(row_text(context, 24, 0), "1 v3 pitch  0>100%")
  -- min and max in 1 %, ALT+E3 in 0.1 %
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:back K3:col E3:min")
  enc(3, 20)
  assert_near(S.macros[1].targets[1].min, 0.2, 1e-9, "min 1 % a detent")
  key(1, 1); enc(3, 5); key(1, 0)
  assert_near(S.macros[1].targets[1].min, 0.205, 1e-9, "ALT+E3 0.1 % a detent")
  redraw()
  assert_equal(row_text(context, 24, 0), "1 v3 pitch  20.5>100%", "a tenth shows")
  key(1, 1); enc(3, -5); key(1, 0)
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:back K3:col E3:max")
  enc(3, -10)
  assert_near(S.macros[1].targets[1].max, 0.9, 1e-9, "max")
  redraw()
  assert_equal(row_text(context, 24, 0), "1 v3 pitch  20>90%")
  assert_equal(S.macros[1].targets[1].id, "v3_grain_pitch", "min and max keep the target")
  -- the cursor's part is bright: the max column
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == 24 and entry.text == "90%" then assert_equal(entry.level, 15, "the max at 15") end
    if entry.y == 24 and entry.text == "20" then assert_true(entry.level < 15, "the min dimmer") end
  end
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:back K3:col E3:target", "K3 wraps to the target column")
  -- inverted: min above max
  macros.set_target(1, 1, "v3_grain_pitch", 0.9, 0.2); redraw()
  assert_equal(row_text(context, 24, 0), "1 v3 pitch  90>20%")
  -- row 8 scrolls into view
  enc(2, 7); redraw()
  assert_equal(row_text(context, 52, 0), "8 -", "row 8 at the bottom")
  assert_screen_layout(context, "the target view at row 8")
  tap(2); redraw()
  assert_equal(S.mod_page.view, "list", "K2 goes back")
  assert_equal(cursor_label(context), "M1", "to the macro's row")
end)

-- Ruling 80 (#595): no surface on MOD touches a target, so learn waits
-- across page changes, the header saying so on every page
test("ALT+K3 in the target view learns the next setting touched, on any page", function()
  local context, S = loaded()
  local macros = S.lib.macros
  place(S, "source:macro2")
  tap(3); enc(2, 1)  -- row 2
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K3:learn E3:group", "an empty row: nothing for ALT+K2 to do")
  tap(3); key(1, 0)
  local m, k = macros.learning()
  assert_equal(m, 2); assert_equal(k, 2, "learn armed for M2 row 2")
  show_page("VOICE")
  assert_equal(macros.learning(), 2, "a page change keeps learn armed")
  assert_equal(header_notice(context), "learn M2 row 2", "and VOICE's header says it waits")
  assert_screen_layout(context, "VOICE while learn waits")
  voice_e3(S, 3, "v3_grain_pitch", 1)
  assert_equal(S.macros[2].targets[2].id, "v3_grain_pitch", "VOICE's E3 learned the param it turned")
  assert_equal(S.macros[2].targets[2].min, 0); assert_equal(S.macros[2].targets[2].max, 1)
  assert_equal(macros.learning(), nil, "learn is done")
  assert_equal(header_notice(context), "M2 > v3 pitch", "the learned flash in the notice's place")
  context.clock.run_for(1.51)
  assert_equal(header_notice(context), nil, "then the dots: the notice is gone")
  -- K2 in the view still cancels it, on MOD after another page
  show_page("MOD")
  assert_equal(S.mod_page.view, "targets", "MOD still shows M2's targets")
  key(1, 1); tap(3); key(1, 0)
  assert_true(macros.learning() ~= nil, "armed again")
  show_page("LFO"); show_page("MOD")
  tap(2)
  assert_equal(macros.learning(), nil, "K2 cancels")
  assert_equal(S.mod_page.view, "list")
  assert_equal(header_notice(context), nil, "and the notice goes with it")
  -- and so does its timeout, on any page
  tap(3); key(1, 1); tap(3); key(1, 0)
  show_page("FX")
  context.clock.run_for(9.9)
  assert_equal(header_notice(context), "learn M2 row 1", "still waiting at 9.9 s")
  context.clock.run_for(0.2)
  assert_equal(macros.learning(), nil, "10 s without a touch cancel it")
  assert_equal(header_notice(context), nil, "and the notice")
end)

-- A touch learn refuses leaves it waiting, and its notice comes back once
-- the refusal's flash ends
test("learn waits on through a touch it refuses: a macro, or an LFO param for a routing", function()
  local context, S = loaded()
  context.arc.plug(1)
  local macros, matrix = S.lib.macros, S.lib.matrix
  place(S, "source:macro1"); tap(3)
  key(1, 1); tap(3); key(1, 0)
  assert_equal(macros.learning(), 1, "M1 row 1 waits")
  local macro = params:get("macro_1")
  context.arc.turn(1, 3, 100)                  -- the target view's ring 3: the macro
  assert_true(params:get("macro_1") > macro, "ring 3 moved macro 1")
  assert_equal(S.lib.ui_flash.text("header"), "not a macro target", "a macro is refused")
  assert_equal(macros.learning(), 1, "learn waits on")
  assert_equal(macros.targets(1)[1].id, "", "the row is still empty")
  context.clock.run_for(1.51)
  assert_equal(header_notice(context), "learn M1 row 1", "the notice is back after the refusal")
  tap(2)
  place(S, "routing:1"); tap(3); enc(2, 1)      -- R1's dest row
  key(1, 1); tap(3); key(1, 0)
  assert_equal(matrix.learning(), 1, "R1's destination waits")
  show_page("LFO")
  enc(2, -20); enc(2, 4)                       -- the strip's depth
  local depth = params:get("strata_lfo1_depth")
  enc(3, 1)
  assert_equal(params:get("strata_lfo1_depth"), depth + 1, "LFO's E3 moved LFO 1's depth")
  assert_equal(S.lib.ui_flash.text("header"), "not a destination", "an LFO param is refused")
  assert_equal(matrix.learning(), 1, "learn waits on")
  assert_equal(matrix.routing(1).dest, "", "no destination yet")
  context.clock.run_for(1.51)
  assert_equal(header_notice(context), "learn R1 dest", "the notice is back")
  assert_screen_layout(context, "LFO while learn waits")
end)

test("K3 on a gesture row presses its recorder; ALT+K3 toggles overdub; ALT+K2 held clears it", function()
  local context, S = loaded()
  local gestures = S.lib.gestures
  place(S, "source:gesture1")
  assert_equal(row_text(context, list_row(context, "G1").y, ROW_LABEL_X), "G1 empty")
  tap(3)
  assert_equal(gestures.state(1), "recording", "K3 records")
  context.clock.run_for(0.2)
  delta_with_detent("reverb_mix", 1)
  context.clock.run_for(1)
  redraw()
  assert_equal(row_text(context, list_row(context, "G1").y, ROW_LABEL_X), "G1 rec 1.0 s")
  tap(3)
  assert_equal(gestures.state(1), "playing", "K3 plays")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:clear K3:dub")
  tap(3)
  assert_true(S.gestures[1].overdubbing, "ALT+K3 overdubs")
  tap(3)
  assert_true(not S.gestures[1].overdubbing, "and stops")
  key(2, 1)
  context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  redraw()
  assert_equal(hint_text(context), "K2:clear K3:dub", "held: clear")
  key(2, 0); key(1, 0)
  assert_equal(gestures.state(1), "empty", "ALT+K2 held clears it")
  -- E3 is its quantize
  local quantize = params:get("gesture_1_quantize")
  enc(3, 1)
  assert_equal(params:get("gesture_1_quantize"), quantize + 1, "E3 the quantize")
end)

test("K3 on an LFO row goes to the LFO page with that LFO selected", function()
  local context, S = loaded()
  place(S, "source:lfo4")
  assert_equal(hint_text(context), "K3:lfo E3:depth")
  local depth = params:get("strata_lfo4_depth")
  enc(3, 3)
  assert_equal(params:get("strata_lfo4_depth"), depth + 3, "E3 the depth")
  tap(3)
  assert_equal(S.ui_page, S.constants.UI_PAGES.index.LFO, "the LFO page")
  assert_equal(S.selected_lfo, 4, "with LFO 4 selected")
  assert_true(context ~= nil)
end)

test("a matrix row shows source, destination and depth; K3 opens the routing view", function()
  local context, S = loaded()
  local matrix = S.lib.matrix
  matrix.set_routing(1, "macro2", "reverb_mix"); params:set("matrix_1_depth", -100); params:set("matrix_1", 0)  -- off
  matrix.set_routing(3, "lfo2", "v3_grain_pitch"); params:set("matrix_3_depth", 40)
  matrix.set_routing(4, "lfo1", "")                        -- incomplete
  place(S, "routing:2")                                    -- R1-R5 in view
  local r3 = list_row(context, "R3")
  assert_equal(row_text(context, r3.y, ROW_LABEL_X), "R3 L2>v3 pitch~  +40%")
  assert_equal(r3.level, 8, "a routing that plays, not under the cursor")
  assert_equal(row_text(context, list_row(context, "R5").y, ROW_LABEL_X), "R5 -", "an empty routing")
  local r4 = list_row(context, "R4")
  assert_equal(row_text(context, r4.y, ROW_LABEL_X), "R4 L1>-  0%")
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == r4.y and entry.x >= ROW_LABEL_X then assert_equal(entry.level, 4, "an incomplete routing at 4") end
  end
  local r1 = list_row(context, "R1")
  assert_equal(row_text(context, r1.y, ROW_LABEL_X), "R1 M2>rev mix  -100%")
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == r1.y and entry.x >= ROW_LABEL_X then assert_equal(entry.level, 4, "an off routing at 4") end
  end
  assert_screen_layout(context, "matrix rows")
  -- an unknown part is drawn as stored, cut to its column
  matrix.set_routing(7, "later_source", "v9_wobble")
  place(S, "routing:7")
  assert_true(row_text(context, list_row(context, "R7").y, ROW_LABEL_X):find("^R7 later_s"), "the stored text")
  assert_screen_layout(context, "an unknown routing")
  place(S, "routing:3")
  assert_equal(hint_text(context), "K3:edit E3:depth")
  enc(3, 2)
  assert_equal(params:get("matrix_3_depth"), 42, "E3 the depth")
  tap(3); redraw()
  assert_equal(S.mod_page.view, "routing")
  assert_equal(row_text(context, 16, 0), "R3 routing  on")
  assert_equal(row_text(context, 24, 0), "source  L2")
  assert_equal(row_text(context, 31, 0), "dest  v3 pitch~")
  assert_equal(row_text(context, 38, 0), "depth  +42%")
  assert_equal(row_text(context, 45, 0), "on  on")
end)

test("the routing view edits source, destination, depth and on, and learns a destination", function()
  local context, S = loaded()
  context.arc.plug(1)
  local matrix = S.lib.matrix
  local sources = S.lib.mod_sources.list()
  local dests = matrix.destination_ids()
  place(S, "routing:1"); tap(3); redraw()
  assert_equal(row_text(context, 24, 0), "source  -")
  assert_equal(hint_text(context), "K2:back K3:off E3:source")
  enc(3, 1)
  assert_equal(matrix.routing(1).source, sources[1].key, "E3: the first source")
  key(1, 1); enc(3, 1); key(1, 0)
  local first_other
  for _, record in ipairs(sources) do
    if record.section ~= sources[1].section then first_other = first_other or record end
  end
  assert_equal(matrix.routing(1).source, first_other.key, "ALT+E3 jumps a section")
  enc(2, 1); redraw()
  assert_equal(hint_text(context), "K2:back K3:off E3:dest")
  enc(3, 1)
  assert_equal(matrix.routing(1).dest, dests[1], "E3: the first destination")
  assert_equal(params:get("matrix_1_depth"), 25, "a completed routing at depth 0 gets 25 %")
  key(1, 1); enc(3, 1); key(1, 0)
  assert_equal(matrix.routing(1).dest, "v1_main", "ALT+E3 jumps a group: the globals, then v1")
  enc(2, 1); enc(3, 5)
  assert_equal(params:get("matrix_1_depth"), 30, "E3 the depth")
  enc(2, 1); enc(3, -1)
  assert_equal(params:get("matrix_1"), 0, "E3 off")
  redraw()
  assert_equal(row_text(context, 16, 0), "R1 routing  off")
  assert_equal(hint_text(context), "K2:back K3:on E3:on")
  tap(3)
  assert_equal(params:get("matrix_1"), 1, "K3 on")
  -- learn on the dest row
  enc(2, -2)
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:learn E3:group")
  tap(3); key(1, 0)
  assert_equal(matrix.learning(), 1, "learn armed")
  -- no surface on MOD touches a destination: learn waits across the page
  -- change (ruling 80), and an arc ring on FX learns
  show_page("FX")
  assert_equal(matrix.learning(), 1, "a page change keeps learn armed")
  assert_equal(header_notice(context), "learn R1 dest", "FX's header says learn waits")
  context.arc.turn(1, 4, 10)                   -- FX's ring 4: the delay mix
  assert_equal(matrix.routing(1).dest, "delay_mix", "the ring's param")
  assert_equal(S.lib.ui_flash.text("header"), "R1 > dly mix")
  assert_equal(matrix.learning(), nil, "learn is done")
  show_page("MOD")
  assert_equal(S.mod_page.view, "routing", "MOD still shows R1")
  -- K2 cancels and goes back
  key(1, 1); tap(3); key(1, 0)
  assert_equal(matrix.learning(), 1)
  tap(2)
  assert_equal(matrix.learning(), nil, "K2 cancels")
  assert_equal(S.mod_page.view, "list")
  -- ALT+K2 held clears the routing
  tap(3)
  alt_k2_held(context); key(2, 0); key(1, 0)
  local routing = matrix.routing(1)
  assert_equal(routing.source .. "|" .. routing.dest .. "|" .. routing.depth, "||0", "cleared")
end)

-- Ruling 77: the routing view's sources are every registered source, the
-- macros of every bank among them, whatever bank the list shows
test("the routing view offers every source, whatever bank is shown", function()
  local context, S = loaded()
  local matrix = S.lib.matrix
  assert_equal(S.lib.macros.bank(), 1, "bank 1 shown")
  place(S, "routing:1"); tap(3)
  -- none, L1-L6, then M1-M16: M9 is 15 steps from none, M16 seven more
  enc(3, 15)
  assert_equal(matrix.routing(1).source, "macro9", "E3 reaches M9")
  redraw()
  assert_equal(row_text(context, 24, 0), "source  M9")
  enc(3, 7)
  assert_equal(matrix.routing(1).source, "macro16", "and M16")
  -- a routing whose source is M9 steps to its neighbors
  matrix.set_routing(2, "macro9", "reverb_mix")
  tap(2); place(S, "routing:2"); tap(3)
  enc(3, -1)
  assert_equal(matrix.routing(2).source, "macro8", "M9 steps down to M8")
  enc(3, 2)
  assert_equal(matrix.routing(2).source, "macro10", "and up to M10")
  -- arc ring 2 draws M9 at its own place: 15 of 27 steps (none, 6 LFOs,
  -- 16 macros, 4 recorders, the input)
  local device = context.arc.plug(1)
  matrix.set_routing(2, "macro9", "reverb_mix"); arc_redraw()
  assert_near(device.segments[2].to, 15 / 27 * math.pi * 2, 1e-9, "ring 2 at M9's place")
  -- an unknown key shows as stored and steps away from none, as before
  matrix.set_routing(2, "later_source", "reverb_mix"); redraw()
  assert_equal(row_text(context, 24, 0), "source  later_source")
  enc(3, 1)
  assert_equal(matrix.routing(2).source, "lfo1", "from none to the first source")
  -- the list still shows the shown bank's macros only
  tap(2); place(S, "bank")
  assert_true(list_row(context, "M1") and not list_row(context, "M9"), "the list keeps bank 1")
end)

-- The rows are built once and kept until what they are built from changes
-- (a source registered, a source's visibility: the shown bank)
test("MOD builds its rows once and keeps them until a source or the shown bank changes", function()
  local context, S = loaded()
  local real_list = S.lib.mod_sources.list
  local calls = 0
  S.lib.mod_sources.list = function(...) calls = calls + 1; return real_list(...) end
  local record = S.registry.pages[S.constants.UI_PAGES.index.MOD]
  local function frame()
    calls = 0
    record.animates(); redraw()
    return calls
  end
  local sections = 7  -- macros morph scatter gestures lfos matrix audio: one list call each
  local first = frame()
  assert_true(first <= sections, "one build at most in a frame: " .. first .. " list calls")
  assert_equal(frame(), 0, "nothing changed: no build")
  S.lib.macros.set_bank(2)
  assert_true(frame() > 0, "a bank change rebuilds")
  assert_true(list_row(context, "M5") ~= nil, "and shows the new bank")
  assert_equal(frame(), 0)
  S.register_mod_source({ key = "probe", name = "PRB", section = "probes", range = { 0, 1 },
    value = function() return 0 end })
  assert_true(frame() > 0, "a registration rebuilds")
  S.lib.mod_sources.list = real_list
end)

test("ALT+K2 randomizes scatter's depth and rate, and the complete routings' depths, with an undo", function()
  local context, S = loaded()
  math.randomseed(7)
  place(S, "scatter")
  alt_k2_quick()
  local depth, rate = params:get("scatter_depth"), params:get("scatter_rate")
  assert_true(depth >= 0 and depth <= 30 and depth % 1 == 0, "a whole depth in 0..30: " .. depth)
  assert_true(rate >= 0.02 - 1e-9 and rate <= 0.5 + 1e-9, "a rate in 0.02..0.5: " .. rate)
  assert_true(depth ~= 10 or math.abs(rate - 0.1) > 1e-6, "something changed")
  alt_k2_quick()
  assert_equal(params:get("scatter_depth"), 10, "a second quick press undoes the depth")
  assert_near(params:get("scatter_rate"), 0.1, 1e-9, "and the rate")
  -- the matrix: every complete routing's depth, the others kept
  local matrix = S.lib.matrix
  matrix.set_routing(1, "lfo1", "reverb_mix"); params:set("matrix_1_depth", 10)
  matrix.set_routing(2, "lfo2", "v1_grain_size"); params:set("matrix_2", 0); params:set("matrix_2_depth", 20)
  matrix.set_routing(3, "lfo3", ""); params:set("matrix_3_depth", 33)
  place(S, "routing:5")
  alt_k2_quick()
  for _, k in ipairs({ 1, 2 }) do
    local value = params:get("matrix_" .. k .. "_depth")
    assert_true(value >= -50 and value <= 50 and value % 1 == 0, "R" .. k .. " a whole depth in -50..50: " .. value)
  end
  assert_equal(params:get("matrix_3_depth"), 33, "an incomplete routing keeps its depth")
  assert_equal(params:get("matrix_5_depth"), 0, "an empty one too")
  alt_k2_quick()
  assert_equal(params:get("matrix_1_depth"), 10, "undone")
  assert_equal(params:get("matrix_2_depth"), 20)
  -- a quick press on a macro, morph, gesture or LFO row changes nothing
  for _, id in ipairs({ "bank", "source:macro1", "morph", "morph_a", "source:gesture1", "source:lfo1" }) do
    place(S, id)
    local before = param_snapshot()
    alt_k2_quick()
    assert_equal(param_snapshot(), before, id .. ": nothing randomized")
  end
  assert_true(context ~= nil)
end)

test("every param a MOD randomize draws ends the undo when edited by hand", function()
  local context, S = loaded()
  local matrix = S.lib.matrix
  matrix.set_routing(1, "lfo1", "reverb_mix"); params:set("matrix_1_depth", 10)
  local cases = {
    { row = "scatter_depth", ids = { "scatter_depth", "scatter_rate" } },
    { row = "routing:1", ids = { "matrix_1_depth" } },
  }
  for _, case in ipairs(cases) do
    for _, id in ipairs(case.ids) do
      place(S, case.row)
      alt_k2_quick()
      assert_true(S.undo ~= nil, case.row .. ": an undo is held")
      enc_param_delta(3, id, 1)
      assert_equal(S.undo, nil, "an edit of " .. id .. " ends it")
    end
  end
  assert_true(context ~= nil)
end)

-- 3a (design §5.5): the morph section's rows A, B, C, D (the corners'
-- scenes, by label), morph and y (the two axes, in percent); E3 steps a
-- corner's scene and moves an axis, as on A, B and morph
test("the morph section shows C, D and y", function()
  local context, S = loaded()
  S.lib.scenes.set_name(3, "dusk")
  params:set("morph_d", 12); params:set("morph_y", 0.35)
  place(S, "morph_c")
  assert_equal(row_text(context, list_row(context, "C").y, ROW_LABEL_X), "C  S3 dusk", "C shows its slot's label")
  assert_equal(row_text(context, list_row(context, "D").y, ROW_LABEL_X), "D  S12", "D an unnamed slot")
  place(S, "morph_y")
  assert_equal(row_text(context, list_row(context, "y").y, ROW_LABEL_X), "y  35%", "y in percent")
  assert_equal(cursor_label(context), "y", "the cursor on y")
  enc(3, 5)
  assert_near(params:get("morph_y"), 0.4, 1e-9, "E3 moves y")
  -- the order: A, B, C, D, then the axes morph and y
  place(S, "morph")
  local morph_row, y_row, d_row = list_row(context, "morph"), list_row(context, "y"), list_row(context, "D")
  assert_true(morph_row and y_row and d_row, "D, morph and y in view")
  assert_equal(y_row.y - morph_row.y, 8, "y follows morph")
  assert_equal(morph_row.y - d_row.y, 8, "morph follows D")
  place(S, "morph_c")
  assert_equal(list_row(context, "D").y - list_row(context, "C").y, 8, "D follows C")
  assert_equal(list_row(context, "C").y - list_row(context, "B").y, 8, "C follows B")
  place(S, "morph_c")
  enc(3, 2)
  assert_equal(params:get("morph_c"), 5, "E3 steps C's scene")
  place(S, "morph_d")
  enc(3, -1)
  assert_equal(params:get("morph_d"), 11, "and D's")
  local function hints_on(id, alt)
    place(S, id)
    if alt then key(1, 1); redraw() end
    local text = hint_text(context)
    if alt then key(1, 0) end
    return text
  end
  assert_equal(hints_on("morph_c"), "E3:scene")
  assert_equal(hints_on("morph_d"), "E3:scene")
  assert_equal(hints_on("morph_y"), "E3:morph")
  assert_equal(hints_on("morph_c", true), "", "C: no ALT key acts")
  assert_equal(hints_on("morph_y", true), "E3:fine", "y: no K2 part, fine as morph")
  assert_screen_layout(context, "the morph section")
end)

test("the hint row names each row's keys", function()
  local context, S = loaded()
  local function hints_on(id, alt)
    place(S, id)
    if alt then key(1, 1); redraw() end
    local text = hint_text(context)
    if alt then key(1, 0) end
    return text
  end
  assert_equal(hints_on("bank"), "K3:bank E3:bank")
  assert_equal(hints_on("source:macro1"), "K3:targets E3:value")
  assert_equal(hints_on("morph_a"), "E3:scene")
  assert_equal(hints_on("morph"), "E3:morph")
  assert_equal(hints_on("scatter"), "K3:on E3:on/off")
  params:set("scatter", 1)
  assert_equal(hints_on("scatter"), "K3:off E3:on/off")
  assert_equal(hints_on("scatter_depth"), "E3:depth")
  assert_equal(hints_on("scatter_rate"), "E3:rate")
  assert_equal(hints_on("scatter_pitch"), "K3:off E3:on/off", "pitch is on by default")
  assert_equal(hints_on("source:gesture1"), "K3:rec E3:quant")
  assert_equal(hints_on("source:lfo1"), "K3:lfo E3:depth")
  assert_equal(hints_on("routing:1"), "K3:edit E3:depth")
  assert_equal(hints_on("source:input"), "E3:gain")
  -- with ALT the K2 part says what ALT+K2 does on the row (ruling 76): rand
  -- where the section randomizes, clear where only the hold acts and would
  -- clear something, nothing where it does nothing
  assert_equal(hints_on("scatter", true), "K2:rand", "scatter randomizes")
  assert_equal(hints_on("scatter_rate", true), "K2:rand E3:fine")
  assert_equal(hints_on("bank", true), "", "the bank row: no ALT key acts")
  assert_equal(hints_on("source:macro1", true), "E2:bank E3:fine", "a macro row: no K2 part")
  assert_equal(hints_on("morph", true), "E3:fine", "morph: no K2 part")
  assert_equal(hints_on("source:lfo1", true), "E3:fine", "an LFO row: no K2 part")
  assert_equal(hints_on("source:gesture1", true), "", "an empty recorder: neither clear nor overdub acts")
  assert_equal(hints_on("routing:1", true), "K3:off E3:fine", "an empty routing, none complete: nothing to randomize or clear")
  S.lib.matrix.set_routing(1, "lfo1", "reverb_mix")
  assert_equal(hints_on("routing:2", true), "K2:rand K3:off E3:fine", "a complete routing: the section randomizes")
  S.lib.matrix.set_routing(1, "lfo1", "")
  assert_equal(hints_on("routing:1", true), "K2:clear K3:off E3:fine", "an incomplete routing: only the hold clears it")
  S.lib.matrix.clear(1)
  -- the gesture row's hints while it plays, and once K2 is held
  place(S, "source:gesture1")
  tap(3); delta_with_detent("reverb_mix", 1); context.clock.run_for(0.5); tap(3)
  assert_equal(hints_on("source:gesture1"), "K3:stop E3:quant")
  assert_equal(hints_on("source:gesture1", true), "K2:clear K3:dub")
  alt_k2_held(context); redraw()
  assert_equal(hint_text(context), "K2:clear K3:dub")
  key(1, 0); redraw()
  assert_equal(hint_text(context), "K2:clear", "K1 let go while K2 is down: K2's hint alone")
  key(2, 0)                                   -- the held press releases through alt_key_release: it clears
  assert_equal(S.lib.gestures.state(1), "empty", "the hold cleared G1")
  assert_equal(hints_on("source:gesture1", true), "", "emptied: no K2 and no K3 part")
  S.lib.gestures.press(1)                     -- recording again (no move yet)
  assert_equal(S.lib.gestures.state(1), "recording")
  assert_equal(hints_on("source:gesture1", true), "K2:clear", "a recording recorder: the hold ends and empties it")
  -- a recorder that holds a loop and is stopped: recorded, played, stopped
  delta_with_detent("reverb_mix", 1); context.clock.run_for(0.5)
  tap(3); tap(3)
  assert_equal(S.lib.gestures.state(1), "stopped", "K3 played it, K3 again stopped it")
  assert_equal(hints_on("source:gesture1"), "K3:play E3:quant")
  assert_equal(hints_on("source:gesture1", true), "K2:clear", "stopped: the hold clears its loop; no overdub")
  alt_k2_held(context); redraw()
  assert_equal(hint_text(context), "K2:clear", "held on the stopped recorder")
  key(2, 0); key(1, 0)
  assert_equal(S.lib.gestures.state(1), "empty", "letting go cleared the stopped loop")
  -- a row that randomizes and has nothing to hold cancels; one that does
  -- nothing shows no K2 part, held or not
  place(S, "scatter_depth")
  alt_k2_held(context); redraw()
  assert_equal(hint_text(context), "K2:cancel E3:fine")
  key(2, 0); key(1, 0)
  place(S, "source:macro1")
  alt_k2_held(context); redraw()
  assert_equal(hint_text(context), "E2:bank E3:fine")
  key(2, 0); key(1, 0)
  -- the views: a target row with a target clears, an empty one has no K2 part
  place(S, "source:macro1"); tap(3)
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K3:learn E3:group", "an empty target row")
  key(1, 0)
  S.lib.macros.set_target(1, 1, "reverb_mix", 0, 1)
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:clear K3:learn E3:group", "a row with a target")
  key(1, 0)
  assert_screen_layout(context, "the hints")
end)

end

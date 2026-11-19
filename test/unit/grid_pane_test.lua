-- test/unit/grid_pane_test.lua
-- The pane engine (lib/grid/pane.lua, design §10.1-§10.2): the page
-- registry, the panes of each layout and their keys, the strips, the 64's
-- chooser, fader lines and the drift tick's follow. Pages are probes
-- (h.probe_grid_page) or absent (h.no_grid_page), so no test leans on
-- which pages main has; keys are named in pane coordinates (h.grid_pane)
-- Run alone: lua test/run.lua grid_pane

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane, probe_grid_page, no_grid_page = h.grid_pane, h.probe_grid_page, h.no_grid_page

local function S_table() return local_value("S") end
local function PAGES() return S_table().constants.GRID_PAGES end
local function core() return S_table().lib.grid_core end

-- The strip keys' places (lib/grid/pane.lua's STRIPS): the upper and lower
-- strips are play or tempo -, fill or tempo +, the seven page keys, then
-- the seven voice or mute keys; the small strip is the chooser key, then
-- the voices
local STRIP = {play = 1, fill = 2, tempo_down = 1, tempo_up = 2, first_page = 3, first_voice = 10,
  first_mute = 10, chooser = 1, small_first_voice = 2, line = 8}
local function page_key(page) return STRIP.first_page + page - 1 end

-- A 64's chooser key, column c and row r of the grid, in the pane's
-- coordinates (on the right half its columns are 9-16)
local function chooser_x(c) return local_value("S").lib.grid_core.half(1, 1) == 2 and c + 8 or c end

-- A fresh load with no record on pages 2-7: a probe goes where a test puts it
local function load_bare()
  local context = load_strata(); finish_startup(context)
  for page = 2, PAGES().count do no_grid_page(page) end
  return context
end

local function raises_naming(fn, name, what)
  local ok, err = pcall(fn)
  assert_true(not ok, what .. ": refused")
  assert_true(tostring(err):find(name, 1, true) ~= nil, what .. ": the error names " .. name .. ": " .. tostring(err))
end

-- Step 1: the registry and the constants ------------------------------

test("register_grid_page refuses a duplicate index, a name that is not the index's, sides 3, a record with no redraw, an unknown field", function()
  load_strata()
  local S = S_table()
  local pages = PAGES()
  local press, redraw = function() end, function() end
  no_grid_page(pages.faders)
  raises_naming(function() S.register_grid_page({name = "patterns", index = pages.patterns, press = press, redraw = redraw}) end,
    "register_grid_page", "a second record at the patterns' index")
  raises_naming(function() S.register_grid_page({name = "scenes", index = pages.faders, press = press, redraw = redraw}) end,
    "register_grid_page", "a name that is not the index's")
  raises_naming(function() S.register_grid_page({name = "faders", index = pages.faders, sides = 3, press = press, redraw = redraw}) end,
    "register_grid_page", "sides 3")
  raises_naming(function() S.register_grid_page({name = "faders", index = pages.faders, press = press}) end,
    "register_grid_page", "no redraw")
  raises_naming(function() S.register_grid_page({name = "faders", index = pages.faders, press = press, redraw = redraw, color = 1}) end,
    "register_grid_page", "an unknown field")
  raises_naming(function() S.register_grid_page({name = "faders", index = pages.count + 1, press = press, redraw = redraw}) end,
    "register_grid_page", "an index past the pages")
  assert_equal(S.registry.grid_pages[pages.faders], nil, "nothing was registered")
  S.register_grid_page({name = "faders", index = pages.faders, sides = 2, press = press, redraw = redraw})
  assert_equal(S.registry.grid_pages[pages.faders].sides, 2, "a whole record is registered at its index")
end)

test("the strips sum to sixteen keys", function()
  load_strata()
  local S = S_table()
  assert_equal(2 + PAGES().count + S.constants.NUM_VOICES, 16, "two keys, the page keys and the voices")
  local strips = S.lib.grid_pane.STRIPS
  assert_equal(#strips.upper, 16, "the upper strip")
  assert_equal(#strips.lower, 16, "the lower strip")
  assert_equal(#strips.small, 1 + S.constants.NUM_VOICES, "the 64's strip: the chooser and the voices")
  assert_equal(strips.upper[STRIP.fill], "fill")
  assert_equal(strips.lower[STRIP.tempo_up], "tempo +")
  assert_equal(strips.upper[page_key(7)], "page 7")
  assert_equal(strips.lower[STRIP.first_mute + 6], "mute 7")
  assert_equal(strips.small[STRIP.chooser], "chooser")
end)

-- Step 2: pages per port and pane ---------------------------------------

test("set_page accepts a page with no record, drawn dark", function()
  local context = load_strata(); finish_startup(context)
  local pages = PAGES()
  no_grid_page(pages.fx)
  local pane = grid_pane(context, "128h")
  S_table().patterns[1][3] = 15
  grid_redraw()
  assert_equal(pane.led(3, 1), 15, "patterns shows the step")
  core().set_page(1, pages.fx)
  grid_redraw()
  assert_equal(core().page(1), pages.fx, "the page is shown")
  for y = 1, 7 do
    for x = 1, 16 do assert_equal(pane.led(x, y), 0, "dark at " .. x .. "," .. y) end
  end
  assert_equal(pane.led(page_key(pages.fx), STRIP.line), 0, "its page key is dark")
  pane.tap(3, 1)
  assert_equal(S_table().patterns[1][3], 15, "its keys do nothing")
  core().set_page(1, pages.patterns, 1, 2)
  assert_equal(core().page(1), pages.fx, "a side a one-sided page has not is refused")
  core().set_page(1, pages.count + 1)
  assert_equal(core().page(1), pages.fx, "a page past the count is refused")
  core().set_page(1, pages.patterns, 2)
  assert_equal(core().page(1, 2), pages.patterns, "a 128h has no pane 2: page(1, 2) reads the start")
  assert_equal(core().page(1), pages.fx, "and pane 1 is left as it is")
end)

test("a page change ends only its pane's keys", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  probe_grid_page(pages.fx)
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  bottom.show(pages.patterns)
  params:set("tempo", 120)
  bottom.press(STRIP.tempo_up, STRIP.line, 1)
  context.clock.run_for(0.55)
  assert_equal(params:get("tempo"), 122, "T+ pressed and repeated once")
  top.press(STRIP.fill, STRIP.line, 1)
  assert_true(S.lib.conditions.fill(), "FL holds fill")
  bottom.press(5, 2, 1)  -- a step held in pane 2
  top.press(6, 3, 1)     -- and one in pane 1
  top.tap(page_key(pages.fx), STRIP.line)
  assert_equal(core().page(1, 1), pages.fx, "pane 1 shows the probe")
  assert_equal(core().page(1, 2), pages.patterns, "pane 2 still shows patterns")
  context.clock.run_for(0.1)
  assert_equal(params:get("tempo"), 123, "the held T+ keeps repeating")
  assert_true(S.lib.conditions.fill(), "FL keeps fill on")
  top.press(6, 3, 0)
  assert_equal(S.patterns[3][6], 0, "the step held in pane 1 toggles nothing")
  bottom.press(5, 2, 0)
  assert_equal(S.patterns[2][5], 15, "the step held in pane 2 toggles at its release")
  bottom.press(STRIP.tempo_up, STRIP.line, 0)
  top.press(STRIP.fill, STRIP.line, 0)
  assert_true(not S.lib.conditions.fill(), "FL's release ends fill")
end)

test("a probe key held under on_hold on a two-sided probe page acts on neither side after its pane shows the other side, and the other pane's held probe key still fires", function()
  local context = load_bare()
  local pages = PAGES()
  local probe = probe_grid_page(pages.fx, {sides = 2, hold = 0.5})
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.fx); bottom.show(pages.fx)
  top.press(3, 2, 1)
  bottom.press(4, 5, 1)
  top.tap(page_key(pages.fx), STRIP.line)  -- the lit page key: side 2
  assert_equal(core().side(1, 1), 2, "pane 1 shows the second side")
  context.clock.run_for(1)
  assert_equal(#probe.fired, 1, "one hold fired")
  assert_equal(probe.fired[1].pane, 2, "the other pane's")
  assert_equal(probe.fired[1].x, 4)
  top.press(3, 2, 0); bottom.press(4, 5, 0)
end)

test("a 128h with a probe key held, turned to 8x16, fires nothing and starts on patterns", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  local probe = probe_grid_page(pages.fx, {hold = 0.5})
  local pane = grid_pane(context, "128h")
  pane.show(pages.fx)
  pane.press(3, 2, 1)
  h.resize_grid(context, 1, 8, 16)
  context.clock.run_for(1)
  assert_equal(#probe.fired, 0, "the hold never fires")
  assert_equal(core().layout_of(1), S.registry.grid_layouts["128v"], "the port now has the 8x16 layout")
  assert_equal(core().page(1), pages.patterns, "it starts on patterns")
  assert_equal(core().held(1, 3, 2), nil, "no key is held")
end)

test("any_page(n, side) is true while any pane of any grid shows it", function()
  local context = load_bare()
  local pages = PAGES()
  probe_grid_page(pages.fx, {sides = 2})
  assert_true(not core().any_page(pages.patterns), "no grid: no page shown")
  local bottom = grid_pane(context, "256 bottom")
  local small = grid_pane(context, "64 left", {port = 2})
  assert_true(core().any_page(pages.patterns), "patterns is shown")
  assert_true(not core().any_page(pages.fx), "the probe is not")
  bottom.show(pages.fx, 2)
  assert_true(core().any_page(pages.fx), "pane 2 of the 256 shows the probe")
  assert_true(core().any_page(pages.fx, 2), "on its second side")
  assert_true(not core().any_page(pages.fx, 1), "not on its first")
  small.show(pages.fx, 1)
  assert_true(core().any_page(pages.fx, 1), "the 64 shows its first side")
  context.grid.unplug(1); context.grid.unplug(2)
  assert_true(not core().any_page(pages.fx), "no grid left: nothing shown")
end)

test("view(port, pane) changes with page, side and half", function()
  local context = load_bare()
  local pages = PAGES()
  probe_grid_page(pages.fx, {sides = 2})
  local small = grid_pane(context, "64 left")
  assert_equal(core().view(1, 1), "1:1:1:1", "pane 1, patterns, side 1, half 1")
  small.show(pages.fx, 2, 1)
  assert_equal(core().view(1, 1), "1:7:2:1", "the page and side")
  core().set_half(1, 1, 2)
  assert_equal(core().view(1, 1), "1:7:2:2", "the half")
  assert_equal(core().half(1, 1), 2)
  assert_equal(core().view(1), core().view(1, 1), "pane defaults to 1")
end)

-- Step 3: the arranger and the strips ------------------------------------

test("the upper strip on a 128h and a 256", function()
  for _, arrangement in ipairs({"128h", "256 top"}) do
    local context = load_bare()
    local S = S_table()
    local pages = PAGES()
    probe_grid_page(pages.fx)
    local pane = grid_pane(context, arrangement)
    local line = STRIP.line
    assert_equal(pane.led(STRIP.play, line), 4, arrangement .. ": PL 4 while stopped")
    pane.tap(STRIP.play, line)
    assert_true(S.pattern_playing, arrangement .. ": PL plays")
    assert_equal(pane.led(STRIP.play, line), 15, arrangement .. ": PL 15 while playing")
    pane.tap(STRIP.play, line)
    assert_true(not S.pattern_playing, arrangement .. ": PL stops")
    assert_equal(pane.led(STRIP.fill, line), 4, arrangement .. ": FL 4 while fill is off")
    pane.press(STRIP.fill, line, 1)
    assert_true(S.lib.conditions.fill(), arrangement .. ": FL held is fill")
    assert_equal(pane.led(STRIP.fill, line), 15, arrangement .. ": FL 15 while fill is on")
    pane.press(STRIP.fill, line, 0)
    assert_true(not S.lib.conditions.fill(), arrangement .. ": FL's release ends it")
    assert_equal(pane.led(page_key(pages.patterns), line), 15, arrangement .. ": the shown page 15")
    assert_equal(pane.led(page_key(pages.fx), line), 2, arrangement .. ": a page with a record 2")
    assert_equal(pane.led(page_key(pages.faders), line), 0, arrangement .. ": a page with no record 0")
    pane.tap(page_key(pages.fx), line)
    assert_equal(core().page(1, pane.pane), pages.fx, arrangement .. ": P7 shows page 7")
    assert_equal(pane.led(page_key(pages.fx), line), 15)
    assert_equal(pane.led(page_key(pages.patterns), line), 2)
    assert_equal(pane.led(STRIP.first_voice, line), 12, arrangement .. ": O1 12, voice 1 running")
    assert_equal(pane.led(STRIP.first_voice + 4, line), 2, arrangement .. ": O5 2, voice 5 stopped")
    pane.tap(STRIP.first_voice + 4, line)
    assert_true(S.voices[5].active, arrangement .. ": O5 starts voice 5")
    assert_equal(pane.led(STRIP.first_voice + 4, line), 12)
    params:set("v5_mute", 1)
    grid_redraw()
    assert_equal(pane.led(STRIP.first_voice + 4, line), 6, arrangement .. ": 6 while silenced")
    params:set("v5_mute", 0)
    pane.tap(STRIP.first_voice + 4, line)
    assert_true(not S.voices[5].active, arrangement .. ": and stops it")
  end
end)

test("row 16's tempo keys step by 1, flash, and repeat while held", function()
  local context = load_bare()
  local S = S_table()
  local bottom = grid_pane(context, "256 bottom")
  local line = STRIP.line
  params:set("tempo", 120)
  grid_redraw()
  assert_equal(bottom.led(STRIP.tempo_up, line), 4, "T+ 4 while up")
  bottom.tap(STRIP.tempo_up, line)
  assert_equal(params:get("tempo"), 121, "T+ adds 1")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 121", "and flashes the tempo")
  bottom.tap(STRIP.tempo_down, line)
  assert_equal(params:get("tempo"), 120, "T- takes 1")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 120")
  -- held: again after 0.5 s, then every 0.1 s (0.95 s, off the 1 s boundary)
  bottom.press(STRIP.tempo_up, line, 1)
  assert_equal(bottom.led(STRIP.tempo_up, line), 15, "15 while held")
  context.clock.run_for(0.45)
  assert_equal(params:get("tempo"), 121, "no repeat before 0.5 s")
  context.clock.run_for(0.5)
  assert_equal(params:get("tempo"), 126, "held 0.95 s: start + 6")
  bottom.press(STRIP.tempo_up, line, 0)
  context.clock.run_for(1)
  assert_equal(params:get("tempo"), 126, "the release stops it")
  assert_equal(bottom.led(STRIP.tempo_up, line), 4)
  bottom.press(STRIP.tempo_down, line, 1)
  context.clock.run_for(0.55)
  bottom.press(STRIP.tempo_down, line, 0)
  assert_equal(params:get("tempo"), 124, "T- repeats too")
end)

test("row 16's mutes", function()
  local context = load_bare()
  local bottom = grid_pane(context, "256 bottom")
  local line = STRIP.line
  local mute_3 = STRIP.first_mute + 2
  assert_equal(bottom.led(mute_3, line), 4, "M3 4 while not muted")
  bottom.tap(mute_3, line)
  assert_equal(params:get("v3_mute"), 1, "M3 mutes voice 3")
  assert_equal(bottom.led(mute_3, line), 15, "15 while muted")
  params:set("v3_mute", 0)
  grid_redraw()
  assert_equal(bottom.led(mute_3, line), 4, "a mute set elsewhere shows")
  bottom.tap(mute_3, line)
  bottom.tap(mute_3, line)
  assert_equal(params:get("v3_mute"), 0, "a second tap unmutes")
end)

test("a page key of a page with no record is dark and dead", function()
  local context = load_strata(); finish_startup(context)
  local pages = PAGES()
  no_grid_page(pages.fx)
  for _, arrangement in ipairs({"128h", "256 bottom"}) do
    local pane = grid_pane(context, arrangement)
    pane.show(pages.patterns)
    assert_equal(pane.led(page_key(pages.fx), STRIP.line), 0, arrangement .. ": dark")
    pane.tap(page_key(pages.fx), STRIP.line)
    assert_equal(core().page(1, pane.pane), pages.patterns, arrangement .. ": and dead")
    context.grid.unplug(1)
  end
end)

test("the lit page key shows the next side and lights 10", function()
  local context = load_bare()
  local pages = PAGES()
  probe_grid_page(pages.fx, {sides = 2})
  local pane = grid_pane(context, "128h")
  local key = page_key(pages.fx)
  pane.tap(key, STRIP.line)
  assert_equal(core().side(1), 1, "a page key shows its page's first side")
  assert_equal(pane.led(key, STRIP.line), 15)
  pane.tap(key, STRIP.line)
  assert_equal(core().side(1), 2, "the lit key pressed again shows the second side")
  assert_equal(pane.led(key, STRIP.line), 10, "its light tells the side")
  pane.tap(key, STRIP.line)
  assert_equal(core().side(1), 1, "and back")
  assert_equal(pane.led(key, STRIP.line), 15)
  pane.tap(page_key(pages.patterns), STRIP.line)
  pane.tap(page_key(pages.patterns), STRIP.line)
  assert_equal(core().side(1), 1, "a one-sided page's lit key changes nothing")
  assert_equal(pane.led(page_key(pages.patterns), STRIP.line), 15)
end)

test("a 256 starts on patterns over voices, over patterns while voices has no record", function()
  local context = load_bare()
  local pages = PAGES()
  probe_grid_page(pages.voices)
  grid_pane(context, "256 top")
  assert_equal(core().page(1, 1), pages.patterns, "the top pane starts on patterns")
  assert_equal(core().page(1, 2), pages.voices, "the bottom on voices")
  context.grid.unplug(1)
  no_grid_page(pages.voices)
  local bottom = grid_pane(context, "256 bottom")
  assert_equal(core().page(1, 2), pages.patterns, "with no voices record, patterns")
  assert_equal(bottom.led(page_key(pages.patterns), STRIP.line), 15, "and its key is lit")
  assert_equal(#S_table().registry.grid_layouts["256"].start_pages, 2, "the 256 names two start pages")
end)

test("the chooser's column 8 and rows 5-7 are dark and do nothing", function()
  local context = load_bare()
  local pages = PAGES()
  local probe = probe_grid_page(pages.fx, {redraw = "all"})
  local small = grid_pane(context, "64 left")
  small.show(pages.fx)
  small.press(STRIP.chooser, STRIP.line, 1)
  context.clock.run_for(0.55)
  for y = 1, 7 do
    assert_equal(small.led(8, y), 0, "column 8 dark at row " .. y)
  end
  for y = 5, 7 do
    for x = 1, 8 do assert_equal(small.led(x, y), 0, "row " .. y .. " dark at " .. x) end
  end
  small.tap(8, 1)
  small.tap(3, 6)
  assert_equal(#probe.presses, 0, "the page saw none of them")
  assert_equal(core().view(1, 1), "1:7:1:1", "and nothing changed")
  small.press(STRIP.chooser, STRIP.line, 0)
end)

test("NV: a tap plays at release; held 0.5 s the chooser picks page, side and half; its release plays nothing; the chooser opening ends a held step", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  probe_grid_page(pages.fx, {sides = 2})
  local small = grid_pane(context, "64 left")
  local line = STRIP.line
  -- a tap plays at its release
  small.press(STRIP.chooser, line, 1)
  assert_true(not S.pattern_playing, "nothing at the press")
  small.press(STRIP.chooser, line, 0)
  assert_true(S.pattern_playing, "the release plays")
  assert_equal(small.led(STRIP.chooser, line), 15, "NV shows the play state: 15 playing")
  small.tap(STRIP.chooser, line)
  assert_true(not S.pattern_playing, "a second tap stops")
  assert_equal(small.led(STRIP.chooser, line), 4)
  assert_equal(small.led(STRIP.small_first_voice, line), 12, "O1 on the 64's strip")
  -- a held step ends as the chooser opens (held 0.25 s: no step editor)
  small.press(STRIP.chooser, line, 1)
  context.clock.run_for(0.3)
  small.press(5, 2, 1)
  context.clock.run_for(0.15)
  assert_equal(small.led(STRIP.chooser, line), 4, "held 0.45 s: the chooser is still closed")
  assert_equal(small.led(1, 2), 0, "and the pane still shows patterns (the chooser would light it 4)")
  context.clock.run_for(0.1)
  assert_equal(small.led(STRIP.chooser, line), 15, "15 while the chooser shows")
  assert_equal(small.led(1, 1), 15, "the shown choice: patterns, side 1, left half")
  assert_equal(small.led(1, 2), 4, "patterns' right half")
  assert_equal(small.led(1, 3), 0, "a one-sided page has no side 2")
  assert_equal(small.led(pages.faders, 1), 0, "a page with no record is dark")
  assert_equal(small.led(pages.fx, 4), 4, "the two-sided probe's side 2, right half")
  small.press(5, 2, 0)
  assert_equal(S.patterns[2][5], 0, "the held step toggles nothing")
  -- a press picks page, side and half at once; the chooser stays
  small.tap(chooser_x(pages.fx), 4)
  assert_equal(core().view(1, 1), "1:7:2:2", "page 7, side 2, right half")
  assert_equal(small.led(chooser_x(pages.fx), 4), 15, "the chooser stays, lit at the new choice")
  small.tap(chooser_x(pages.faders), 1)
  assert_equal(core().view(1, 1), "1:7:2:2", "a page with no record is dead")
  small.tap(chooser_x(pages.patterns), 2)
  assert_equal(core().view(1, 1), "1:1:1:2", "patterns, right half")
  small.press(STRIP.chooser, line, 0)
  assert_true(not S.pattern_playing, "NV's release after the chooser plays nothing")
  grid_redraw()
  S.patterns[1][12] = 15
  grid_redraw()
  assert_equal(small.led(12, 1), 15, "the chooser closed: the right half's steps show")
end)

test("a chooser key's release does nothing", function()
  local context = load_bare()
  local S = S_table()
  local small = grid_pane(context, "64 left")
  small.press(STRIP.chooser, STRIP.line, 1)
  context.clock.run_for(0.55)
  small.press(chooser_x(1), 2, 1)  -- patterns, right half
  small.press(STRIP.chooser, STRIP.line, 0)
  small.press(chooser_x(1), 2, 0)  -- released after the chooser closed: column 1 is step 9 now
  assert_equal(S.patterns[2][9], 0, "the key's release reaches no step")
  assert_equal(core().view(1, 1), "1:1:1:2")
end)

-- Step 4: fader lines and the follow -------------------------------------

test("a fader line sets exactly 0 at its zero column at 16 and at 8 keys", function()
  local context = load_bare()
  local pages = PAGES()
  local zero_16 = fader_zero_column("v1_pan")
  assert_equal(zero_16, 9, "a symmetric range's zero column at 16 keys")
  assert_equal(fader_zero_column("v1_pan", 16), zero_16, "16 is the default width")
  local zero_8 = fader_zero_column("v1_pan", 8)
  assert_true(zero_8 >= 2 and zero_8 <= 7, "at 8 keys within 2-7: " .. tostring(zero_8))
  params:set("v1_pan", 1)
  set_param_from_column("v1_pan", zero_8, 8)
  assert_equal(params:get("v1_pan"), 0, "the 8-key zero column sets exactly 0")
  assert_equal(fader_position("v1_pan", 8), zero_8, "and 0 shows there")
  set_param_from_column("v1_pan", 1, 8)
  assert_equal(params:get("v1_pan"), -1, "key 1 the minimum")
  set_param_from_column("v1_pan", 8, 8)
  assert_equal(params:get("v1_pan"), 1, "key 8 the maximum")
  -- through a fader line on each arrangement
  probe_grid_page(pages.fx, {faders = {{line = 1, first = 1, keys = 16, id = "v1_pan"}}})
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local pane = grid_pane(context, arrangement)
    pane.show(pages.fx)
    local width = arrangement:find("^64") and 8 or 16
    local offset = arrangement == "64 right" and 8 or 0
    local zero = fader_zero_column("v1_pan", width)
    local zero_x = arrangement == "128v" and (16 + 1 - zero) or (offset + zero)
    params:set("v1_pan", 1)
    pane.tap(zero_x, 1)
    assert_equal(params:get("v1_pan"), 0, arrangement .. ": the zero key sets 0")
    assert_equal(pane.led(zero_x, 1), 15, arrangement .. ": and lights there")
    context.grid.unplug(1)
  end
end)

test("the 128v's fader runs up", function()
  local context = load_bare()
  local pages = PAGES()
  local probe = probe_grid_page(pages.fx, {faders = {{line = 1, first = 1, keys = 16, id = "v1_amp"}}})
  local pane = grid_pane(context, "128v")
  pane.show(pages.fx)
  local spec = params:lookup_param("v1_amp").controlspec
  pane.tap(16, 1)  -- physical row 16
  assert_equal(params:get("v1_amp"), spec.minval, "row 16 the minimum")
  assert_equal(pane.led(16, 1), 15, "its value lit at row 16")
  pane.tap(1, 1)   -- physical row 1
  assert_equal(params:get("v1_amp"), spec.maxval, "row 1 the maximum")
  assert_equal(pane.led(1, 1), 15)
  assert_equal(pane.led(16, 1), 8, "the bar runs up from row 16")
  assert_equal(#probe.presses, 0, "the page never sees a fader line's keys")
  pane.tap(1, 2)
  assert_equal(#probe.presses, 2, "it sees its other keys")
end)

test("the 64 draws a 16-key fader across eight keys on either half, an 8-key fader only on its half", function()
  local context = load_bare()
  local pages = PAGES()
  local probe = probe_grid_page(pages.fx, {faders = {{line = 1, first = 1, keys = 16, id = "v1_amp"},
    {line = 2, first = 9, keys = 8, id = "v2_amp"}}})
  local spec = params:lookup_param("v1_amp").controlspec
  local small = grid_pane(context, "64 left")
  small.show(pages.fx)
  small.tap(8, 1)
  assert_equal(params:get("v1_amp"), spec.maxval, "left half: key 8 the 16-key fader's maximum")
  small.tap(1, 1)
  assert_equal(params:get("v1_amp"), spec.minval, "key 1 its minimum")
  assert_equal(small.led(1, 1), 15)
  local before = params:get("v2_amp")
  small.tap(4, 2)
  assert_equal(params:get("v2_amp"), before, "the 8-key fader is not on the left half")
  assert_equal(#probe.presses, 2, "the page sees that key")
  small.show(pages.fx, 1, 2)
  small.tap(16, 1)
  assert_equal(params:get("v1_amp"), spec.maxval, "right half: key 16 the 16-key fader's maximum")
  assert_equal(small.led(16, 1), 15)
  assert_equal(small.led(9, 1), 8, "its bar across the half")
  small.tap(16, 2)
  assert_equal(params:get("v2_amp"), spec.maxval, "the 8-key fader on its half")
  small.tap(9, 2)
  assert_equal(params:get("v2_amp"), spec.minval)
  assert_equal(#probe.presses, 2, "no fader key reached the page")
end)

test("the drift tick redraws a grid when a shown fader line or a page's signature changes, and idle ticks repaint nothing", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  local mark = {value = "a"}
  probe_grid_page(pages.fx, {faders = {{line = 1, first = 1, keys = 16, id = "v1_amp"}},
    signature = function() return mark.value end})
  local pane = grid_pane(context, "128h")
  local follow = S.lib.grid_faders.follow_faders
  follow()
  local refreshes = pane.device.refresh_count
  follow(); follow()
  assert_equal(pane.device.refresh_count, refreshes, "patterns alone: idle ticks repaint nothing")
  pane.show(pages.fx)
  follow()
  refreshes = pane.device.refresh_count
  follow(); follow()
  assert_equal(pane.device.refresh_count, refreshes, "idle ticks on the probe repaint nothing")
  params:set("v1_amp", 0)
  follow()
  assert_equal(pane.device.refresh_count, refreshes + 1, "a shown fader moved: one redraw")
  assert_equal(pane.led(1, 1), 15, "the fader shows its new value")
  mark.value = "b"
  follow()
  assert_equal(pane.device.refresh_count, refreshes + 2, "the page's signature changed: one redraw")
  follow()
  assert_equal(pane.device.refresh_count, refreshes + 2, "and idle again")
end)

test("a page whose redraw fails spares the other pane and the strips, and prints once", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  probe_grid_page(pages.fx, {redraw = function() error("broken page") end})
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.fx)
  bottom.show(pages.patterns)
  S.patterns[2][4] = 15
  for _ = 1, 3 do grid_redraw() end
  assert_equal(bottom.led(4, 2), 15, "the other pane is drawn")
  assert_equal(top.led(page_key(pages.fx), STRIP.line), 15, "the failing pane's strip is drawn")
  assert_equal(bottom.led(page_key(pages.patterns), STRIP.line), 15, "and the other's")
  h.claim_script_errors(context, 1, "strata: grid page redraw failed: ", "broken page")
end)

-- The pane object's interface (the review's T1) ----------------------------

-- What a probe page saw of its pane at each press: the fields and what
-- each wrapper answered for the key pressed
local function interface_probe(pages)
  local seen = {}
  local probe = probe_grid_page(pages.fx)
  probe.press = function(pane, x, y, z)
    if z ~= 1 then
      seen.release = (seen.release or 0) + 1
      return
    end
    seen.width, seen.offset, seen.turned = pane.width, pane.offset, pane.turned
    seen.shows_x, seen.shows_left, seen.shows_right = pane.shows(x), pane.shows(1), pane.shows(16)
    seen.held = pane.held(x, y) ~= nil
    seen.off_pane = pane.held(x, 8)  -- line 8 is no pane key
    seen.pending_before = pane.hold_pending(x, y)
    pane.on_hold(x, y, 0.5, function() seen.fired = (seen.fired or 0) + 1 end)
    seen.pending_after = pane.hold_pending(x, y)
    pane.press_as(x, y, "probe")
    seen.role = pane.pressed_as(x, y, "probe") and not pane.pressed_as(x, y, "other")
    pane.consume(x, y)
    seen.consumed = pane.consumed(x, y)
    local state = pane.state()
    state.presses = (state.presses or 0) + 1
    seen.state = state
  end
  return probe, seen
end

test("the pane object's fields and wrappers on every arrangement, the 128v and the 64's right half among them", function()
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_bare()
    local S = S_table()
    local pages = PAGES()
    local _, seen = interface_probe(pages)
    local pane = grid_pane(context, arrangement)
    pane.show(pages.fx)
    local x = arrangement == "64 right" and 11 or 3
    pane.press(x, 2, 1)
    local half = arrangement:find("^64") ~= nil
    assert_equal(seen.width, half and 8 or 16, arrangement .. ": width")
    assert_equal(seen.offset, arrangement == "64 right" and 8 or 0, arrangement .. ": offset")
    assert_equal(seen.turned, arrangement == "128v", arrangement .. ": turned")
    assert_true(seen.shows_x, arrangement .. ": shows the key pressed")
    assert_equal(seen.shows_left, arrangement ~= "64 right", arrangement .. ": shows column 1")
    assert_equal(seen.shows_right, arrangement ~= "64 left", arrangement .. ": shows column 16")
    assert_true(seen.held, arrangement .. ": held(x, y) is the key's press time")
    assert_equal(seen.off_pane, nil, arrangement .. ": a strip line is no pane key")
    assert_true(not seen.pending_before and seen.pending_after, arrangement .. ": hold_pending follows on_hold")
    assert_true(seen.role, arrangement .. ": press_as and pressed_as")
    assert_true(seen.consumed, arrangement .. ": consume and consumed")
    context.clock.run_for(0.6)
    assert_equal(seen.fired, 1, arrangement .. ": on_hold fired once")
    pane.press(x, 2, 0)
    assert_equal(seen.release, nil, arrangement .. ": the consumed key's release never reached the page")
    assert_equal(seen.state.presses, 1, arrangement .. ": state() kept the count")
    assert_equal(S.lib.grid_core.port_state(1).pages.fx, seen.state, arrangement .. ": at port_state(port).pages[name]")
    -- gesture_key in pane coordinates: a tap of recorder 1 records
    local probe = S.registry.grid_pages[pages.fx]
    probe.press = function(p, px, py, z) p.gesture_key(px, py, z, 1) end
    pane.tap(x, 3)
    assert_equal(S.lib.gestures.state(1), "recording", arrangement .. ": gesture_key at its release")
    S.lib.gestures.clear(1)
  end
end)

-- The controller's ruling on C1: a page's state is port_state(port).pages[name]
test("a page's state() is per port and page, never the positions module's record, and goes with the grid", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  local states = {}
  local probe = probe_grid_page(pages.positions)
  probe.press = function(pane, _, _, z)
    if z == 1 then states[#states + 1] = pane.state() end
  end
  local top = grid_pane(context, "256 top")
  local small = grid_pane(context, "64 left", {port = 2})
  top.show(pages.positions); small.show(pages.positions)
  top.tap(2, 1)
  small.tap(2, 1)
  top.tap(3, 1)
  assert_true(states[1] ~= states[2], "each port its own")
  assert_equal(states[1], states[3], "one table a port and page")
  assert_equal(S.lib.grid_core.port_state(1).pages.positions, states[1], "kept at port_state(port).pages[name]")
  -- the positions module's record at port_state(port).positions is its own
  S.buffers[1].seconds = 16
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.positions.strip_key(1, 1, "store", 1)
  S.lib.positions.strip_key(1, 1, "store", 0)
  assert_true(S.lib.grid_core.port_state(1).positions ~= states[1], "the page's state is not the module's record")
  assert_equal(states[1].hold, nil, "and holds none of its fields")
  context.grid.unplug(1)
  assert_equal(S.lib.grid_core.existing_port_state(1), nil, "unplugged: the port's state, pages included, is gone")
  assert_true(S.lib.grid_core.port_state(2).pages.positions == states[2], "the other grid keeps its own")
end)

-- The controller's ruling on C2: a page's faders and signature run contained
test("a page whose faders or signature raises is contained: no fader lines, an unchanged signature, the tick goes on", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  local broken = {faders = true, signature = false}
  local probe = probe_grid_page(pages.fx, {
    faders = function() if broken.faders then error("broken faders") end return {} end,
    signature = function() if broken.signature then error("broken signature") end return "s" end,
    redraw = function(_, led) led(1, 1, 9) end})
  local pane = grid_pane(context, "128h")
  pane.show(pages.fx)
  for _ = 1, 3 do grid_redraw() end
  assert_equal(pane.led(1, 1), 9, "the page is drawn, as having no fader lines")
  assert_true(pcall(drift_update), "the drift tick does not raise")
  assert_true(pcall(drift_update), "nor the next")
  pane.tap(1, 2)
  assert_equal(#probe.presses, 2, "its keys still reach the page")
  h.claim_script_errors(context, 1, "strata: grid page faders failed: ", "broken faders")
  broken.faders, broken.signature = false, true
  local follow = S.lib.grid_faders.follow_faders
  assert_true(pcall(follow), "a raising signature is contained")
  local refreshes = pane.device.refresh_count
  follow(); follow()
  assert_equal(pane.device.refresh_count, refreshes, "and reads as unchanged: idle ticks repaint nothing")
  h.claim_script_errors(context, 1, "strata: grid page signature failed: ", "broken signature")
end)

-- #854: the containment is per pane: on a 256, the top pane's raising
-- faders or signature never cost the bottom pane its fader lines or its
-- signature's follow
test("on a 256 a page whose faders or signature raises spares the other pane's", function()
  local context = load_bare()
  local S = S_table()
  local pages = PAGES()
  local broken = {faders = true, signature = false}
  probe_grid_page(pages.fx, {
    faders = function() if broken.faders then error("broken faders") end return {} end,
    signature = function() if broken.signature then error("broken signature") end return "s" end})
  local other = {signature = "a"}
  probe_grid_page(pages.scenes, {faders = {{line = 1, first = 1, keys = 16, id = "delay_mix"}},
    signature = function() return other.signature end})
  local top = grid_pane(context, "256 top", {port = 1})
  local bottom = grid_pane(context, "256 bottom", {port = 1})
  top.show(pages.fx); bottom.show(pages.scenes)
  grid_redraw()
  bottom.tap(16, 1)
  assert_equal(params:get("delay_mix"), 1, "the bottom pane's fader line sets its param")
  assert_equal(bottom.led(16, 1), 15, "and shows it")
  params:set("delay_mix", 0)
  assert_true(pcall(drift_update), "the drift tick does not raise")
  assert_equal(bottom.led(1, 1), 15, "the bottom pane's line shows its param")
  h.claim_script_errors(context, 1, "strata: grid page faders failed: ", "broken faders")
  broken.faders, broken.signature = false, true
  local follow = S.lib.grid_faders.follow_faders
  assert_true(pcall(follow), "a raising signature is contained")
  follow()
  local refreshes = bottom.device.refresh_count
  follow()
  assert_equal(bottom.device.refresh_count, refreshes, "an idle tick repaints nothing")
  other.signature = "b"
  follow()
  assert_true(bottom.device.refresh_count > refreshes, "the bottom pane's signature change still repaints")
  h.claim_script_errors(context, 1, "strata: grid page signature failed: ", "broken signature")
end)

test("h.grid_pane's show raises when the pane does not end on the page, side and half asked for", function()
  local context = load_bare()
  local pages = PAGES()
  probe_grid_page(pages.fx)
  local pane = grid_pane(context, "128h")
  local ok, err = pcall(pane.show, pages.fx, 2)
  assert_true(not ok, "a side the page lacks is refused, so show raises")
  assert_true(tostring(err):find("shows", 1, true) ~= nil, "naming what it shows: " .. tostring(err))
  assert_true(pcall(pane.show, pages.fx, 1), "a side it has is shown")
end)

-- Step 5: every key of every registered page -----------------------------

test("every key of every registered page runs on every arrangement", function()
  local context = load_strata(); finish_startup(context)
  local S = S_table()
  local pages = PAGES()
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local pane = grid_pane(context, arrangement)
    for page = 1, pages.count do
      local record = S.registry.grid_pages[page]
      for side = 1, record and record.sides or 1 do
        for y = 1, 7 do
          for x = 1, 16 do
            pane.show(page, side)
            if pane.shows(x, y) then
              pane.press(x, y, 1); pane.press(x, y, 0)
              context.clock.advance()
            end
          end
        end
      end
    end
    assert_true(pane.device.refresh_count > 0, arrangement .. ": drawn")
    context.grid.unplug(1)
  end
  if S.pattern_playing then pattern_toggle() end
end)

end

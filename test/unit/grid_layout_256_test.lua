-- test/unit/grid_layout_256_test.lua
-- The 16x16 grid layout (lib/grid/layout_256.lua, 3.8's arranger): two
-- panes, rows 1-7 over rows 9-15, row 8 the top pane's strip (play, fill,
-- its page keys, the voices) and row 16 the bottom's (tempo, its page
-- keys, the mutes). The pages are their own files' (grid_pages_*_test.lua)
-- Run alone: lua test/run.lua grid_layout_256

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function S_table() return local_value("S") end
local function tap(context, x, y)
  context.grid.press(1, x, y, 1); context.grid.press(1, x, y, 0)
end

-- Row 8: PL 1, FL 2, P1-P7 3-9, O1-O7 10-16; row 16: T- 1, T+ 2, P1-P7
-- 3-9, M1-M7 10-16
local KEYS = {play = 1, fill = 2, first_page = 3, first_voice = 10, tempo_down = 1, tempo_up = 2, top = 8, bottom = 16}
local function page_x(page) return KEYS.first_page + page - 1 end
local function voice_x(voice_idx) return KEYS.first_voice + voice_idx - 1 end

test("the 256's two panes and strips sit where its spec says", function()
  local context = load_strata(); finish_startup(context)
  local S = S_table()
  local layout = S.registry.grid_layouts["256"]
  context.grid.plug(1, 16, 16)
  assert_equal(S.lib.grid_core.layout_of(1), layout, "a 16x16 grid has the 256 layout")
  assert_equal(layout.panes, 2, "two panes")
  assert_equal(layout.pane_at(1, 1), 1, "rows 1-7 are the top pane")
  assert_equal(layout.pane_at(16, 7), 1)
  assert_equal(layout.pane_at(1, 9), 2, "rows 9-15 the bottom")
  assert_equal(layout.pane_at(16, 15), 2)
  assert_equal(layout.pane_at(5, 8), nil, "row 8 is a strip")
  assert_equal(layout.pane_at(5, 16), nil, "and row 16")
  assert_equal(table.concat(layout.start_pages, " "), S.constants.GRID_PAGES.patterns .. " " .. S.constants.GRID_PAGES.voices,
    "it starts on patterns over voices")
  -- a step on each pane
  S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.patterns, 2)
  tap(context, 4, 3); tap(context, 5, 11)
  assert_equal(S.patterns[3][4], 15, "the top pane's line 3 is voice 3")
  assert_equal(S.patterns[3][5], 15, "the bottom pane's line 3 too")
end)

test("grid LEDs follow non-grid state changes (I9) and the played step (M7)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  -- row 8's O keys show voice on/off
  toggle_voice(5)
  assert_equal(device:get_led(voice_x(5), KEYS.top), 12, "voice 5 on lights its O key")
  toggle_voice(5)
  assert_equal(device:get_led(voice_x(5), KEYS.top), 2, "voice 5 off dims it")
  -- row 16's M keys show a mute set anywhere
  params:set("v2_mute", 1)
  assert_equal(device:get_led(voice_x(2), KEYS.bottom), 15, "a mute set off the grid lights M2")
  params:set("v2_mute", 0)

  -- the highlighted step is the one that just played
  toggle_pattern_step(1, 1)
  pattern_toggle()
  assert_equal(device:get_led(1, 1), 15, "step 1 highlighted while it plays")
  assert_equal(device:get_led(2, 1), 1, "step 2 not highlighted: empty, at 1 as the picked voice's")
  assert_equal(device:get_led(1, 2), 4, "empty step under the playhead shows dim")
  pattern_toggle()

  -- grid_redraw with no grids is a no-op
  context.grid.unplug(1)
  assert_equal(next(local_value("grids")), nil, "unplug clears the grids table")
  grid_redraw()
end)

test("grid_redraw draws the 256 layout (I2), on a hot-plugged grid too (I3)", function()
  local context = load_strata()
  local device = context.grid.plug(2, 16, 16)
  local refreshes = device.refresh_count
  grid_redraw()
  assert_equal(device.refresh_count, refreshes + 1, "256 redraw reaches a hot-plugged grid")
  -- voice 1 is running after init: its status LED must be lit
  local lit = false
  for x = 1, 16 do
    for y = 1, 16 do
      if device:get_led(x, y) >= 12 then lit = true end
    end
  end
  assert_true(lit, "256 layout drew something")
end)

test("the play key on row 8 lights with the state (256)", function()
  local context = load_strata()
  local device = context.grid.plug(1, 16, 16)
  assert_equal(device:get_led(KEYS.play, KEYS.top), 4, "dim when stopped")
  tap(context, KEYS.play, KEYS.top)
  assert_true(local_value("pattern_playing"), "PL plays")
  assert_equal(device:get_led(KEYS.play, KEYS.top), 15, "lit while playing")
  tap(context, KEYS.play, KEYS.top)
  assert_true(not local_value("pattern_playing"), "and stops")
  assert_equal(device:get_led(KEYS.play, KEYS.top), 4, "dim after stop")
end)

-- 3.7 (design §5.2, ruling 10): the fill key, FL on row 8 since 3.8
test("row 8, column 2 holds fill while it is down", function()
  local context = load_strata(); finish_startup(context)
  local S = S_table()
  local conditions = S.lib.conditions
  local device = context.grid.plug(1, 16, 16)
  for page = 1, S.constants.GRID_PAGES.count do
    S.lib.grid_core.set_page(1, page); grid_redraw()
    assert_equal(device:get_led(KEYS.fill, KEYS.top), 4, "page " .. page .. ": 4 while fill is off")
    context.grid.press(1, KEYS.fill, KEYS.top, 1)
    assert_true(conditions.fill(), "page " .. page .. ": on at the press")
    assert_equal(device:get_led(KEYS.fill, KEYS.top), 15, "lit 15 while held")
    assert_equal(params:get("seq_fill"), 0, "the hold is no latch")
    context.grid.press(1, KEYS.fill, KEYS.top, 0)
    assert_true(not conditions.fill(), "off at the release")
    assert_equal(device:get_led(KEYS.fill, KEYS.top), 4)
  end
  params:set("seq_fill", 1)
  assert_equal(device:get_led(KEYS.fill, KEYS.top), 15, "the latch lights it")
  tap(context, KEYS.fill, KEYS.top)
  assert_true(conditions.fill(), "a key's release leaves the latch")
  params:set("seq_fill", 0)
  assert_equal(device:get_led(KEYS.fill, KEYS.top), 4)
  -- two grids hold it each on their own
  local other = context.grid.plug(2, 16, 16)
  context.grid.press(1, KEYS.fill, KEYS.top, 1); context.grid.press(2, KEYS.fill, KEYS.top, 1)
  context.grid.press(1, KEYS.fill, KEYS.top, 0)
  assert_true(conditions.fill(), "one grid's release leaves the other's hold")
  assert_equal(other:get_led(KEYS.fill, KEYS.top), 15)
  context.grid.press(2, KEYS.fill, KEYS.top, 0)
  assert_true(not conditions.fill())
end)

-- Ruling 54: a strip key is never ended by a page change; a grid's
-- removal still ends it
test("fill stays held across a page change and ends when its grid is removed", function()
  local context = load_strata(); finish_startup(context)
  local S = S_table()
  local conditions = S.lib.conditions
  local pages = S.constants.GRID_PAGES
  h.probe_grid_page(pages.fx)
  context.grid.plug(1, 16, 16)
  context.grid.press(1, KEYS.fill, KEYS.top, 1)
  assert_true(conditions.fill())
  tap(context, page_x(pages.fx), KEYS.top)
  assert_equal(S.lib.grid_core.page(1), pages.fx, "the top pane shows another page")
  assert_true(conditions.fill(), "a page change leaves fill held")
  tap(context, page_x(pages.patterns), KEYS.bottom)
  assert_true(conditions.fill(), "and so does the bottom pane's")
  context.grid.press(1, KEYS.fill, KEYS.top, 0)
  assert_true(not conditions.fill(), "its release ends it")
  context.grid.press(1, KEYS.fill, KEYS.top, 1)
  assert_true(conditions.fill(), "a new press holds again")
  context.grid.unplug(1)
  assert_true(not conditions.fill(), "the grid's removal ends its hold")
  -- the 128h's too
  context.grid.plug(3, 16, 8)
  context.grid.press(3, KEYS.fill, KEYS.top, 1)
  assert_true(conditions.fill(), "the 128h's FL")
  context.grid.press(3, page_x(pages.fx), KEYS.top, 1); context.grid.press(3, page_x(pages.fx), KEYS.top, 0)
  assert_true(conditions.fill(), "a page change leaves it")
  context.grid.unplug(3)
  assert_true(not conditions.fill(), "the grid's removal ends it")
end)

test("tempo keys light while held and flash the new tempo in the header", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  local S = S_table()
  params:set("tempo", 120)
  grid_redraw()
  for x = KEYS.tempo_down, KEYS.tempo_up do assert_equal(device:get_led(x, KEYS.bottom), 4, "tempo key " .. x .. " at 4") end
  context.grid.press(1, KEYS.tempo_up, KEYS.bottom, 1)
  assert_equal(params:get("tempo"), 121, "T+ adds 1")
  assert_equal(device:get_led(KEYS.tempo_up, KEYS.bottom), 15, "lit while held")
  assert_equal(device:get_led(KEYS.tempo_down, KEYS.bottom), 4, "the other stays at 4")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 121")
  context.grid.press(1, KEYS.tempo_up, KEYS.bottom, 0)
  assert_equal(device:get_led(KEYS.tempo_up, KEYS.bottom), 4, "back to 4 on release")
  tap(context, KEYS.tempo_down, KEYS.bottom)
  assert_equal(S.lib.ui_flash.text("header"), "tempo 120", "T- takes 1")
  -- on every page of the bottom pane
  S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.positions, 2)
  context.grid.press(1, KEYS.tempo_down, KEYS.bottom, 1)
  assert_equal(device:get_led(KEYS.tempo_down, KEYS.bottom), 15, "another page lights a held tempo key")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 119")
  context.grid.press(1, KEYS.tempo_down, KEYS.bottom, 0)
  -- the play key does not flash
  context.clock.run_for(2)
  tap(context, KEYS.play, KEYS.top)
  assert_equal(S.lib.ui_flash.text("header"), nil, "play/stop shows no tempo")
  tap(context, KEYS.play, KEYS.top)
end)

-- The internal clock reports a new tempo only once it has ticked (matron's
-- clock thread publishes it from the tick after next), so the flash shows
-- the tempo param the key set; under MIDI or crow the param sets nothing,
-- and the flash shows what the clock runs (#383)
test("256 tempo keys: the flash shows the tempo the key set on the internal clock", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local S = S_table()
  assert_equal(clock.get_tempo(), 120, "120 BPM to start")
  tap(context, KEYS.tempo_up, KEYS.bottom)
  assert_equal(clock.get_tempo(), 120, "the clock has not ticked yet")
  assert_equal(S.lib.ui_flash.text("header"), "tempo 121", "the tempo the key set")
  params:set("clock_source", 3)   -- link: the param sets the session tempo
  tap(context, KEYS.tempo_up, KEYS.bottom)
  assert_equal(S.lib.ui_flash.text("header"), "tempo 122", "link: the tempo the key set")
end)

test("256 tempo keys: under MIDI or crow the flash shows the clock's tempo", function()
  local context = load_strata(); finish_startup(context)
  context.grid.plug(1, 16, 16)
  local S = S_table()
  for _, source in ipairs({ 2, 4 }) do   -- midi, crow
    params:set("clock_source", source)
    clock.tempo = 97                    -- the external source's tempo
    tap(context, KEYS.tempo_up, KEYS.bottom)
    assert_equal(S.lib.ui_flash.text("header"), "tempo 97", params:string("clock_source") .. ": the clock's tempo")
  end
end)

test("256 lights the sounding step between steps, as SEQ does (#113)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local device = context.grid.plug(1, 16, 16)
  local function led(voice_idx, step) return device:get_led(step, voice_idx) end
  S.patterns[1][2] = 9
  grid_redraw()
  assert_equal(led(1, 2), 9, "stopped: the stored level")
  assert_equal(led(2, 1), 0, "stopped: no playhead")
  pattern_toggle()  -- step 1 plays at once
  grid_redraw()
  assert_equal(led(2, 1), 4, "just started: step 1 is the playhead")
  assert_equal(led(2, PATTERN_LENGTH), 0, "never the last step")
  h.wake(context, "pattern_clock")  -- step 2 plays; the position is now 3
  grid_redraw()  -- a redraw between steps (a key press)
  assert_equal(S.pattern_position, 3)
  assert_equal(led(1, 2), 15, "the sounding active step at 15")
  assert_equal(led(2, 2), 4, "the sounding empty step at 4")
  assert_equal(led(2, 3), 0, "not the next step")
  assert_equal(S.lib.sequencer.sounding_step(), 2, "the step SEQ draws")
  pattern_toggle()
  assert_equal(led(1, 2), 9, "stopped: the stored level again")
  assert_equal(led(2, 2), 0)
end)

test("a silenced voice's key lights at 6 on every layout", function()
  local context = load_strata(); finish_startup(context)
  local device = context.grid.plug(1, 16, 16)
  toggle_voice(3); toggle_voice(5)  -- voices 4, 6 and 7 stay stopped
  assert_equal(device:get_led(voice_x(3), KEYS.top), 12, "voice 3 running: 12")
  params:set("v3_mute", 1)
  assert_equal(device:get_led(voice_x(3), KEYS.top), 6, "voice 3 muted: 6")
  params:set("v3_mute", 0)
  params:set("v5_solo", 1)
  assert_equal(device:get_led(voice_x(3), KEYS.top), 6, "voice 3 silenced by voice 5's solo: 6")
  assert_equal(device:get_led(voice_x(5), KEYS.top), 12, "the soloed voice 5: 12")
  assert_equal(device:get_led(voice_x(4), KEYS.top), 2, "voice 4, stopped and silenced: 2")
  params:set("v5_solo", 0)
  assert_equal(device:get_led(voice_x(3), KEYS.top), 12, "the solo lifted: voice 3 at 12 again")
end)

test("the 256's step keys toggle on release on both panes", function()
  local context = load_strata(); finish_startup(context)
  local S = S_table()
  local patterns = local_value("patterns")
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.patterns, 2)
  for _, y in ipairs({7, 15}) do
    context.grid.press(1, 6, y, 1)
    assert_equal(patterns[7][6], 0, "row " .. y .. ": the press leaves voice 7's step 6")
    context.grid.press(1, 6, y, 0)
    assert_equal(patterns[7][6], 15, "row " .. y .. ": the release toggles it")
    patterns[7][6] = 0
  end
end)

-- A release acts only for the key pressed in its role: a step key held
-- into a probe page and let go there acts on neither page
test("a key held into another page acts there in no role", function()
  local context = load_strata(); finish_startup(context)
  local S = S_table()
  local pages = S.constants.GRID_PAGES
  local acted = {}
  local probe = h.probe_grid_page(pages.fx)
  probe.press = function(pane, x, y, z)
    if z == 1 then
      pane.press_as(x, y, "probe")
    elseif pane.pressed_as(x, y, "probe") then
      acted[#acted + 1] = x .. "," .. y
    end
  end
  context.grid.plug(1, 16, 16)
  local patterns = local_value("patterns")
  context.grid.press(1, 1, 4, 1)  -- patterns: voice 4's step 1
  tap(context, page_x(pages.fx), KEYS.top)
  context.grid.press(1, 1, 4, 0)  -- let go on the probe page
  assert_equal(#acted, 0, "the probe page's key does nothing")
  assert_equal(patterns[4][1], 0, "and the step is untouched")
  context.grid.press(1, 2, 3, 1)  -- the probe's key
  tap(context, page_x(pages.patterns), KEYS.top)
  context.grid.press(1, 2, 3, 0)  -- let go on patterns
  assert_equal(patterns[3][2], 0, "the step under it does nothing")
  -- pressed in its role, the probe's key acts at its release
  tap(context, page_x(pages.fx), KEYS.top)
  tap(context, 2, 3)
  assert_equal(table.concat(acted, " "), "2,3", "a probe key's own tap acts")
end)

end

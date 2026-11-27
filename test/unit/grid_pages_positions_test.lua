-- test/unit/grid_pages_positions_test.lua
-- Grid page 5, positions (lib/grid/pages/positions.lua, design §10.7): side
-- 1 a line of sixteen cells per voice, side 2 every voice's marks and the
-- slots' record and clear keys, on every arrangement (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_positions

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane, shown_step_editor = h.grid_pane, h.shown_step_editor

-- Voices 1-3 on slot 1 (16 s, loaded), each loop the whole slot; voice 4
-- on its synth
local function buffer_voices(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16; S.buffers[1].loaded = true; S.lib.samples.bind(1)  -- settled audio is bound
  for voice_idx = 1, 3 do
    params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1)
    params:set("v" .. voice_idx .. "_loop_length", 1); params:set("v" .. voice_idx .. "_loop_start", 0)
  end
  context.clear_engine_calls()
  return S
end

-- The pane's first and last shown column: a half shows eight
local function shown_columns(pane)
  local first, last
  for x = 1, 16 do
    if pane.shows(x, 1) then
      first = first or x
      last = x
    end
  end
  return first, last
end

-- Side 2's columns: the marks (bookmarks 1-4, ST 6, HD 7, WH 8) and slot n
-- at 8 + n, in pane coordinates
local MARK_X = {store = 6, hold = 7, whole = 8}
local SLOT_X = 8

-- body(context, S, pane, arrangement) on each arrangement (opts.only: a
-- test of keys some arrangements do not show keeps those that show column
-- opts.only), the pane on positions' given side (1 by default)
local function each_arrangement(body, opts)
  opts = opts or {}
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = buffer_voices(context)
    local pane = grid_pane(context, arrangement)
    if opts.only == nil or pane.shows(opts.only, 1) then
      pane.show(S.constants.GRID_PAGES.positions, opts.side or 1)
      body(context, S, pane, arrangement)
    end
  end
end

-- The pane-coordinate x of a strip's key (S.lib.grid_pane.STRIPS), on
-- line 8, the strip's line
local function strip_x(S, strip, name)
  for x, key in ipairs(S.lib.grid_pane.STRIPS[strip]) do
    if key == name then return x end
  end
  error("no key " .. name .. " on the " .. strip .. " strip", 2)
end

local function scan_hold_sent(context)
  local held
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == "scanHold" then held = call.args[3] end
  end
  return held
end

-- 3.7 (design §10): a slice row, on the doubles test/helpers.lua shares
-- (h.slice_doubles): `voice` takes notes and its slot holds `count` slices
local function slice_double(S, voice, count)
  local doubles = h.slice_doubles(S, {[voice_buffer_slot(voice)] = count})
  doubles.takes[voice] = true
  return doubles
end

test("the positions page is registered at its index, with two sides", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.positions]
  assert_true(record ~= nil, "a record at page 5")
  assert_equal(record.name, "positions")
  assert_equal(record.sides, 2, "two sides")
  assert_equal(S.lib.grid_pages_positions.record, record, "the module keeps its record")
end)

-- Side 1 -----------------------------------------------------------------

test("a press jumps and a held pair sets the loop", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    pane.tap(first + 4, 2)
    assert_near(params:get("v2_buf_pos"), (first + 3) / 16, 1e-9, arrangement .. ": line 2 jumps voice 2 to its cell")
    assert_near(params:get("v1_buf_pos"), 0, 1e-9, arrangement .. ": and leaves voice 1")
    pane.press(first, 2, 1); pane.press(first + 4, 2, 1)
    pane.press(first + 4, 2, 0); pane.press(first, 2, 0)
    assert_near(params:get("v2_loop_start"), (first - 1) / 16, 1e-9, arrangement .. ": the earlier cell's start")
    assert_near(params:get("v2_loop_length"), 5 / 16, 1e-9, arrangement .. ": to the later cell's end")
    assert_near(params:get("v2_buf_pos"), 0, 1e-9, arrangement .. ": at the loop's start")
    for _, voice_idx in ipairs({1, 3}) do
      pane.tap(first + 1, voice_idx)
      assert_near(params:get("v" .. voice_idx .. "_buf_pos"), first / 16, 1e-9, arrangement .. ": line " .. voice_idx .. " is voice " .. voice_idx)
    end
    assert_equal(S.grid_voice_select, 1, arrangement .. ": a press never selects the grid voice")
  end)
end)

local function loop_panes(context)
  local page = buffer_voices(context).constants.GRID_PAGES.positions
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(page, 1)
  bottom.show(page, 1)
  return top, bottom
end

test("releasing the older copy of a loop anchor keeps the newer pane's anchor (#1093)", function()
  local context = load_strata(); finish_startup(context)
  local top, bottom = loop_panes(context)
  top.press(4, 1, 1)
  bottom.press(4, 1, 1)
  top.press(4, 1, 0)
  bottom.tap(9, 1)
  assert_near(params:get("v1_loop_start"), 3 / 16, 1e-9)
  assert_near(params:get("v1_loop_length"), 6 / 16, 1e-9)
  assert_near(params:get("v1_buf_pos"), 0, 1e-9)
  bottom.press(4, 1, 0)
end)

test("releasing the newer anchor leaves the older pane's copy superseded", function()
  local context = load_strata(); finish_startup(context)
  local top, bottom = loop_panes(context)
  top.press(4, 1, 1)
  bottom.press(4, 1, 1)
  bottom.press(4, 1, 0)
  top.tap(9, 1)
  assert_near(params:get("v1_loop_length"), 1, 1e-9)
  assert_near(params:get("v1_buf_pos"), 8 / 16, 1e-9)
  top.press(4, 1, 0)
end)

test("different cells across panes pair and detaching clears the anchor", function()
  local context = load_strata(); finish_startup(context)
  local top, bottom = loop_panes(context)
  top.press(4, 1, 1)
  bottom.tap(9, 1)
  assert_near(params:get("v1_loop_start"), 3 / 16, 1e-9)
  assert_near(params:get("v1_loop_length"), 6 / 16, 1e-9)
  context.grid.unplug(1)
  local wide = grid_pane(context, "128h")
  wide.show(local_value("S").constants.GRID_PAGES.positions, 1)
  wide.tap(13, 1)
  assert_near(params:get("v1_loop_length"), 1, 1e-9, "the reconnected port starts with a jump")
  assert_near(params:get("v1_buf_pos"), 12 / 16, 1e-9)
end)

test("a position release on one line keeps another line's held key in the same column (#733)", function()
  each_arrangement(function(_, _, pane, arrangement)
    local first = shown_columns(pane)
    pane.press(first, 1, 1)      -- voice 1's cell
    pane.press(first, 2, 1)      -- voice 2's, the port's held key
    pane.press(first, 1, 0)      -- voice 1's release
    pane.press(first + 4, 2, 1)  -- voice 2's key is still down: a loop
    assert_near(params:get("v2_loop_start"), (first - 1) / 16, 1e-6, arrangement .. ": loop start")
    assert_near(params:get("v2_loop_length"), 5 / 16, 1e-6, arrangement .. ": loop length")
    pane.press(first + 4, 2, 0); pane.press(first, 2, 0)
  end)
end)

test("LEDs follow grid_level", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first, last = shown_columns(pane)
    local cells = S.constants.GRID_PAGES.position_cells
    for voice_idx = 1, S.constants.NUM_VOICES do
      for cell = first, last do
        assert_equal(pane.led(cell, voice_idx), S.lib.positions.grid_level(voice_idx, cell, cells, pane.port),
          arrangement .. ": voice " .. voice_idx .. " cell " .. cell)
      end
    end
    for cell = first, last do assert_equal(pane.led(cell, 4), 0, arrangement .. ": voice 4 reads no buffer") end
    params:set("v1_buf_pos", 0.45)
    S.lib.playheads.reset(1)
    grid_redraw()
    if pane.shows(8, 1) then
      assert_equal(pane.led(8, 1), 15, arrangement .. ": the playhead cell (0.45 of 16 is cell 8)")
      assert_true(pane.led(1, 1) < 15, arrangement .. ": and not the others")
    else
      for cell = first, last do assert_true(pane.led(cell, 1) < 15, arrangement .. ": the playhead is on the other half") end
    end
  end)
end)

test("a slice row plays", function()
  each_arrangement(function(_, S, pane, arrangement)
    local double = slice_double(S, 2, 20)
    grid_redraw()
    local first, last = shown_columns(pane)
    for cell = first, last do assert_equal(pane.led(cell, 2), 9, arrangement .. ": slice " .. cell) end
    pane.press(first + 4, 2, 1)
    assert_equal(double.plays[1].n, first + 4, arrangement .. ": the cell's slice")
    assert_equal(double.plays[1].note.key, 100 + first + 4)
    assert_equal(pane.led(first + 4, 2), 15, arrangement .. ": playing")
    -- a release on another line never ends it
    pane.press(first + 4, 3, 1); pane.press(first + 4, 3, 0)
    assert_equal(#double.offs, 0, arrangement .. ": voice 2's key is still down")
    pane.press(first + 4, 2, 0)
    assert_equal(#double.offs, 1, arrangement .. ": its own release ends it")
    assert_equal(double.offs[1].voice, 2); assert_equal(double.offs[1].key, 100 + first + 4)
    assert_equal(pane.led(first + 4, 2), 9, arrangement .. ": a slice again")
    assert_near(params:get("v2_buf_pos"), 0, 1e-9, arrangement .. ": no jump")
    -- the bank keys are on side 2: bank 2 shows slices 17-32
    pane.show(S.constants.GRID_PAGES.positions, 2)
    if pane.shows(1, 1) then
      assert_equal(pane.led(1, 2), 15, arrangement .. ": bank 1 shown")
      assert_equal(pane.led(2, 2), 4, arrangement .. ": bank 2 holds slices")
      assert_equal(pane.led(3, 2), 0, arrangement .. ": bank 3 none")
      pane.tap(2, 2)
      assert_equal(pane.led(2, 2), 15, arrangement .. ": bank 2 shown")
      assert_equal(pane.led(1, 2), 4)
      pane.show(S.constants.GRID_PAGES.positions, 1)
      assert_equal(pane.led(first + 3, 2), 9, arrangement .. ": slice 20")
      assert_equal(pane.led(first + 4, 2), 0, arrangement .. ": no slice 21")
      pane.tap(first + 3, 2)
      assert_equal(double.plays[2].n, 20, arrangement .. ": bank 2's fourth key")
    end
  end)
end)

-- Side 2 -----------------------------------------------------------------

test("the marks recall, store, hold and restore the whole loop", function()
  each_arrangement(function(context, S, pane, arrangement)
    local positions = S.lib.positions
    pane.tap(2, 2)
    assert_near(params:get("v2_buf_pos"), 0.25, 1e-9, arrangement .. ": bookmark 2 recalled on line 2")
    params:set("v2_buf_pos", 0.6)
    pane.press(MARK_X.store, 2, 1); pane.press(3, 2, 1)
    assert_equal(pane.led(3, 2), positions.LEVELS.stored, arrangement .. ": 15 while it stores")
    pane.press(3, 2, 0); pane.press(MARK_X.store, 2, 0)
    assert_near(positions.bookmark(2, 3), 0.6, 0.05, arrangement .. ": ST held + bookmark 3 stores at the playhead")
    context.clear_engine_calls()
    pane.press(MARK_X.hold, 1, 1)
    assert_equal(positions.scan_held(1), true, arrangement .. ": HD holds line 1's voice")
    assert_equal(scan_hold_sent(context), 1, arrangement .. ": scanHold 1 down")
    assert_equal(pane.led(MARK_X.hold, 1), positions.LEVELS.key_down)
    pane.press(MARK_X.hold, 1, 0)
    assert_equal(scan_hold_sent(context), 0, arrangement .. ": scanHold 0 up")
    params:set("v2_loop_length", 0.5)
    pane.tap(MARK_X.whole, 2)
    assert_near(params:get("v2_loop_start"), 0, 1e-9, arrangement .. ": whole loop")
    assert_near(params:get("v2_loop_length"), 1, 1e-9)
    for voice_idx = 1, S.constants.NUM_VOICES do
      for n = 1, S.constants.NUM_BOOKMARKS do
        assert_equal(pane.led(n, voice_idx), positions.strip_level(voice_idx, n, pane.port), arrangement .. ": bookmark " .. n)
      end
      for mark, x in pairs(MARK_X) do
        assert_equal(pane.led(x, voice_idx), positions.strip_level(voice_idx, mark, pane.port), arrangement .. ": " .. mark)
      end
      assert_equal(pane.led(5, voice_idx), 0, arrangement .. ": column 5 dark")
    end
    assert_equal(pane.led(MARK_X.whole, 2), positions.LEVELS.whole, arrangement .. ": WH lit while whole")
  end, {side = 2, only = 1})
end)

for _, cell in ipairs({8, 7}) do
  test("a jump to cell " .. cell .. " after leaving HD releases the old scan hold (#1092)", function()
    local context = load_strata(); finish_startup(context)
    local S = buffer_voices(context)
    local pane = grid_pane(context, "128h")
    local positions_key = strip_x(S, "upper", "page " .. S.constants.GRID_PAGES.positions)
    local voices_key = strip_x(S, "upper", "page " .. S.constants.GRID_PAGES.voices)
    pane.tap(positions_key, 8)
    pane.tap(positions_key, 8)  -- marks
    pane.press(MARK_X.hold, 1, 1)
    assert_equal(S.lib.positions.scan_held(1), true, "HD holds the scan")
    pane.tap(voices_key, 8)
    pane.press(MARK_X.hold, 1, 0)
    pane.tap(positions_key, 8)  -- cells, before the next playhead tick
    pane.press(cell, 1, 1)
    assert_near(params:get("v1_buf_pos"), (cell - 1) / 16, 1e-9, "the new press jumps")
    context.clock.run_for(0.5)
    assert_equal(S.lib.positions.scan_held(1), false, "the scan runs while the jump key is down")
    assert_equal(scan_hold_sent(context), 0, "the engine received the release")
    pane.press(cell, 1, 0)
  end)
end

test("a synth voice's marks are dark and store nothing (#445)", function()
  each_arrangement(function(_, S, pane, arrangement)
    params:set("v1_source", 1)
    grid_redraw()
    for x = 1, 8 do assert_equal(pane.led(x, 1), 0, arrangement .. ": line 1, column " .. x) end
    pane.press(MARK_X.store, 1, 1)
    pane.press(2, 1, 1)
    assert_equal(pane.led(MARK_X.store, 1), 0, arrangement .. ": store held: dark")
    assert_equal(pane.led(2, 1), 0, arrangement .. ": the pressed bookmark: dark")
    assert_equal(params:get("v1_bookmark_2"), 0.25, arrangement .. ": and the bookmark keeps its value")
    pane.press(2, 1, 0); pane.press(MARK_X.store, 1, 0)
    params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
    grid_redraw()
    assert_equal(pane.led(MARK_X.store, 1), S.lib.positions.LEVELS.key_up, arrangement .. ": a buffer voice's store is up")
  end, {side = 2, only = 1})
end)

test("the marks follow an off-grid change within a tick (#322)", function()
  each_arrangement(function(context, S, pane, arrangement)
    local LEVELS = S.lib.positions.LEVELS
    context.clock.run_for(0.5)
    assert_equal(pane.led(MARK_X.whole, 2), LEVELS.whole, arrangement .. ": whole: the loop is the whole slot")
    params:set("v2_loop_length", 0.5)  -- the arc, an LFO or a scene moves the loop
    context.clock.run_for(1 / 15 + 0.01)
    assert_equal(pane.led(MARK_X.whole, 2), LEVELS.key_up, arrangement .. ": WH repainted")
    local device = pane.device
    local before = device.refresh_count
    params:set("v2_bookmark_3", 0.9)  -- BUFFER's field, an arc ring or a scene fade sets the param
    context.clock.run_for(1 / 15 + 0.01)
    assert_equal(device.refresh_count, before + 1, arrangement .. ": a bookmark stored off the grid: one redraw")
    context.clock.run_for(1)
    assert_equal(device.refresh_count, before + 1, arrangement .. ": and no more")
    -- the hold of another grid and of the arc light HD
    context.grid.plug(2, 16, 8)
    S.lib.grid_core.set_page(2, S.constants.GRID_PAGES.positions, 1, 2)
    S.lib.positions.strip_key(2, 1, "hold", 1, 1)
    assert_equal(pane.led(MARK_X.hold, 1), LEVELS.key_down, arrangement .. ": another grid's hold lights HD")
    context.grid.unplug(2)
    context.clock.run_for(0.2)
    assert_equal(S.lib.positions.scan_held(1), false, arrangement .. ": the tick released the gone grid's hold")
    assert_equal(pane.led(MARK_X.hold, 1), LEVELS.key_up, arrangement .. ": and HD goes dark")
  end, {side = 2, only = 1})
end)

test("HD lights while BUFFER's ALT ring 1 holds and goes dark when ALT comes up", function()
  each_arrangement(function(context, S, pane, arrangement)
    local LEVELS = S.lib.positions.LEVELS
    context.arc.plug(1)
    h.show_page("BUFFER")
    assert_equal(S.selected_voice, 1)
    assert_equal(pane.led(MARK_X.hold, 1), LEVELS.key_up, arrangement .. ": not held")
    key(1, 1)
    context.arc.turn(1, 1, 1)
    assert_equal(S.lib.positions.scan_held(1), true, arrangement .. ": the arc holds voice 1")
    assert_equal(pane.led(MARK_X.hold, 1), LEVELS.key_down, arrangement .. ": the arc's hold lights HD")
    key(1, 0)
    assert_equal(S.lib.positions.scan_held(1), false, arrangement .. ": ALT up releases it")
    assert_equal(pane.led(MARK_X.hold, 1), LEVELS.key_up, arrangement .. ": and HD goes dark")
  end, {side = 2, only = 1})
end)

test("a grid moved to another port releases its store and its scan hold", function()
  each_arrangement(function(context, S, pane, arrangement)
    local positions = S.lib.positions
    pane.press(MARK_X.hold, 1, 1)
    pane.press(MARK_X.store, 1, 1)
    assert_equal(positions.scan_held(1), true, arrangement .. ": the grid holds voice 1's scan")
    assert_equal(positions.strip_level(1, "store"), positions.LEVELS.key_down, arrangement .. ": store is down")
    _menu.set_mode(true)  -- SYSTEM > DEVICES
    context.grid.reassign(1, 2)
    _menu.set_mode(false)
    assert_equal(positions.strip_level(1, "store", 2), positions.LEVELS.key_up, arrangement .. ": on its new port the store is up at once")
    local moved = grid_pane(context, arrangement, {port = 2})
    moved.show(S.constants.GRID_PAGES.positions, 2)
    local bookmark = params:get("v1_bookmark_1")
    params:set("v1_buf_pos", 0.6)
    moved.press(1, 1, 1)
    assert_near(params:get("v1_bookmark_1"), bookmark, 1e-9, arrangement .. ": a bookmark press there recalls: nothing stored")
    moved.press(1, 1, 0)
    context.clock.run_for(0.2)
    assert_equal(positions.scan_held(1), false, arrangement .. ": the next playhead tick released the scan hold")
    assert_equal(positions.holds_scan(1, "grid:1"), false, arrangement .. ": the old port holds nothing")
    assert_equal(positions.holds_scan(1, "grid:2"), false, arrangement .. ": nor the new one")
    assert_equal(positions.strip_level(1, "store"), positions.LEVELS.key_up, arrangement .. ": no port holds store")
  end, {side = 2, only = 1})
end)

test("each grid lights only its own store key", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local pages = S.constants.GRID_PAGES
  local full = grid_pane(context, "256 top")
  local wide = grid_pane(context, "128h", {port = 2})
  full.show(pages.positions, 2); wide.show(pages.positions, 2)
  wide.press(MARK_X.store, 1, 1)
  assert_equal(wide.led(MARK_X.store, 1), 15, "the 128h's store key is down")
  assert_equal(full.led(MARK_X.store, 1), 4, "the 256's is not")
  wide.press(MARK_X.store, 1, 0)
  full.press(MARK_X.store, 1, 1)
  assert_equal(full.led(MARK_X.store, 1), 15, "the 256's store key is down")
  assert_equal(wide.led(MARK_X.store, 1), 4, "the 128h's is not")
  full.press(MARK_X.store, 1, 0)
end)

test("side 2's keys record and clear slots 1-8", function()
  each_arrangement(function(context, S, pane, arrangement)
    local NUM_BUFFERS = S.constants.NUM_BUFFERS
    pane.tap(SLOT_X + 5, 1)
    assert_equal(context.calls_named("recordBuffer")[1].args[1], 4, arrangement .. ": line 1, column 13 records slot 5")
    assert_equal(pane.led(SLOT_X + 5, 1), 15, arrangement .. ": lit while it records")
    pane.tap(SLOT_X + 5, 1)
    assert_equal(#context.calls_named("stopRecord"), 1, arrangement .. ": a second press stops it early")
    pane.tap(SLOT_X + 4, 2)
    assert_equal(context.calls_named("clearBuffer")[1].args[1], 3, arrangement .. ": line 2, column 12 clears slot 4")
    for slot = 1, NUM_BUFFERS do
      pane.tap(SLOT_X + slot, 2)
      assert_equal(context.calls_named("clearBuffer")[#context.calls_named("clearBuffer")].args[1], slot - 1,
        arrangement .. ": clear key " .. slot)
    end
    load_buffer(2, "/tmp/a.wav")              -- loaded, not from the grid
    params:set("record_duration", 2); params:set("buf6_record", 1)  -- recording, from params
    for slot = 1, NUM_BUFFERS do
      assert_equal(pane.led(SLOT_X + slot, 1), S.lib.grid_core.record_level(slot), arrangement .. ": record key " .. slot)
      assert_equal(pane.led(SLOT_X + slot, 2), S.lib.grid_core.CLEAR_LEVEL, arrangement .. ": clear key " .. slot)
      for y = 3, S.constants.NUM_VOICES do assert_equal(pane.led(SLOT_X + slot, y), 0, arrangement .. ": line " .. y .. " dark") end
    end
    assert_equal(pane.led(SLOT_X + 6, 1), 15, arrangement .. ": recording")
    assert_equal(pane.led(SLOT_X + 2, 1), 8, arrangement .. ": loaded")
    assert_equal(pane.led(SLOT_X + 3, 1), 2, arrangement .. ": empty")
    context.clear_engine_calls()
    for y = 3, S.constants.NUM_VOICES do pane.tap(SLOT_X + 1, y) end
    assert_equal(#context.calls_named("recordBuffer") + #context.calls_named("clearBuffer"), 0,
      arrangement .. ": lines 3-7 of the slots do nothing")
  end, {side = 2, only = SLOT_X + 1})
end)

test("an armed slot's key lights 11", function()
  each_arrangement(function(context, S, pane, arrangement)
    params:set("record_sync", 3)
    assert_equal(pane.led(SLOT_X + 3, 1), 2, arrangement .. ": empty")
    pane.tap(SLOT_X + 3, 1)
    -- the engine reports take 1 of slot 3 armed: ((1 * 4) + 0) * 8 + 2
    context.polls.fire("recordState", ((1 * 4) + 0) * 8 + 2)
    assert_equal(S.lib.record.state(3).phase, "armed")
    grid_redraw()
    assert_equal(pane.led(SLOT_X + 3, 1), 11, arrangement .. ": armed")
    -- and recording: ((1 * 4) + 1) * 8 + 2
    context.polls.fire("recordState", ((1 * 4) + 1) * 8 + 2)
    grid_redraw()
    assert_equal(pane.led(SLOT_X + 3, 1), 15, arrangement .. ": recording")
  end, {side = 2, only = SLOT_X + 1})
end)

test("a slot's state change redraws a grid on side 2", function()
  each_arrangement(function(context, S, pane, arrangement)
    load_buffer(3, "/tmp/a.wav")
    local before = pane.device.refresh_count
    context.polls.fire("bufferState", context.polls.buffer_state_value(3, 1, 12.5))
    assert_true(pane.device.refresh_count > before, arrangement .. ": the bufferState poll redraws the grid")
    assert_equal(pane.led(SLOT_X + 3, 1), S.lib.grid_core.record_level(3), arrangement .. ": slot 3's key shows it")
  end, {side = 2, only = SLOT_X + 1})
end)

-- #854: the record keys on the grid itself, beyond the core's record_level
test("a finished take's record key goes from 15 to 8, a cleared slot's to 2, a canceled take's back to 8", function()
  each_arrangement(function(context, S, pane, arrangement)
    params:set("record_duration", 2); params:set("buf6_record", 1)
    assert_equal(pane.led(SLOT_X + 6, 1), 15, arrangement .. ": recording")
    h.wake_buffer_clock(context, 6)
    assert_equal(pane.led(SLOT_X + 6, 1), 15, arrangement .. ": a take waiting for the engine stays lit")
    context.polls.fire("bufferState", context.polls.buffer_state_value(6, 0, 3))  -- the engine reports the take
    assert_equal(pane.led(SLOT_X + 6, 1), 8, arrangement .. ": the finished take shows as holding audio")
    clear_buffer(6)
    assert_equal(pane.led(SLOT_X + 6, 1), 2, arrangement .. ": cleared: 2")
    load_buffer(3, "/tmp/a.wav")
    context.polls.fire("bufferState", context.polls.buffer_state_value(3, 1, 12.5))
    assert_equal(pane.led(SLOT_X + 3, 1), 8, arrangement .. ": slot 3 holds audio")
    params:set("record_sync", 3)
    pane.tap(SLOT_X + 3, 1)
    -- the engine reports take 1 of slot 3 armed: ((1 * 4) + 0) * 8 + 2
    context.polls.fire("recordState", ((1 * 4) + 0) * 8 + 2)
    grid_redraw()
    assert_equal(pane.led(SLOT_X + 3, 1), 11, arrangement .. ": armed")
    -- and canceled: ((1 * 4) + 3) * 8 + 2. A canceled replace take shows
    -- the slot empty until the engine's next length report puts back what
    -- it kept (#311's state table)
    context.polls.fire("recordState", ((1 * 4) + 3) * 8 + 2)
    grid_redraw()
    assert_equal(pane.led(SLOT_X + 3, 1), 2, arrangement .. ": canceled: empty until the engine reports")
    context.polls.fire("bufferState", context.polls.buffer_state_value(3, 1, 12.5))
    grid_redraw()
    assert_equal(pane.led(SLOT_X + 3, 1), 8, arrangement .. ": the engine reports the kept audio: 8 again")
  end, {side = 2, only = SLOT_X + 1})
end)

-- Both panes and both sides ------------------------------------------------

test("leaving the bookmark's pane ends its highlight while Store stays down on the 256", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.positions, 2); bottom.show(pages.positions, 2)
  params:set("v1_buf_pos", 0.625)
  top.press(MARK_X.store, 1, 1)
  bottom.press(2, 1, 1)
  assert_equal(top.led(2, 1), 15, "the stored bookmark is bright on both panes")
  bottom.tap(strip_x(S, "lower", "page " .. pages.patterns), 8)
  bottom.press(2, 1, 0)
  context.clock.run_for(0.5)
  assert_equal(top.led(2, 1), 6, "the bookmark is back to steady")
  assert_equal(top.led(MARK_X.store, 1), 15, "the upper pane still holds Store")
  assert_near(params:get("v1_bookmark_2"), 0.625, 1e-6, "the saved bookmark survives")

  bottom.show(pages.positions, 2)
  bottom.press(2, 1, 1)
  bottom.show(pages.positions, 1)
  bottom.press(2, 1, 1)  -- same coordinate, now a jump, before the next tick
  assert_equal(top.led(2, 1), 6, "a new physical press cannot revive the bookmark")
  bottom.press(2, 1, 0)
  top.press(MARK_X.store, 1, 0)
end)

test("two panes holding the same stored bookmark keep it lit until the last release", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(S.constants.GRID_PAGES.positions, 2); bottom.show(S.constants.GRID_PAGES.positions, 2)
  top.press(MARK_X.store, 1, 1)
  for _, order in ipairs({{top, bottom}, {bottom, top}}) do
    top.press(2, 1, 1); bottom.press(2, 1, 1)
    order[1].press(2, 1, 0)
    assert_equal(top.led(2, 1), 15, "the other pane still holds bookmark 2")
    order[2].press(2, 1, 0)
    assert_equal(top.led(2, 1), 6, "the last bookmark key is up")
    assert_equal(top.led(MARK_X.store, 1), 15)
  end
  bottom.press(2, 1, 1)
  context.grid.unplug(1)
  context.clock.run_for(0.5)
  assert_equal(S.lib.positions.strip_level(1, 2), 6, "unplug ends the bookmark press")
  assert_equal(S.lib.positions.strip_level(1, "store"), 4, "unplug ends Store")
end)

test("another grid holding the same bookmark cannot mask the 256's lost release", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  local wide = grid_pane(context, "128h", {port = 2})
  for _, pane in ipairs({top, bottom, wide}) do pane.show(pages.positions, 2) end
  top.press(MARK_X.store, 1, 1); bottom.press(2, 1, 1)
  wide.press(MARK_X.store, 1, 1); wide.press(2, 1, 1)
  context.clock.run_for(0.5)
  bottom.show(pages.faders)
  bottom.press(2, 1, 0)
  context.clock.run_for(0.5)
  assert_equal(top.led(2, 1), 6, "only the wide grid still holds the bookmark")
  assert_equal(wide.led(2, 1), 15)
  assert_equal(top.led(MARK_X.store, 1), 15)
end)

test("Store shows the live press on each grid after a pane leaves Positions", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  local wide = grid_pane(context, "128h", {port = 2})
  for _, pane in ipairs({top, bottom, wide}) do pane.show(pages.positions, 2) end
  bottom.press(MARK_X.store, 1, 1)
  wide.press(MARK_X.store, 1, 1)
  context.clock.run_for(0.5)
  assert_equal(top.led(MARK_X.store, 1), 15, "the lower pane holds Store for this grid")
  bottom.show(pages.patterns)
  assert_equal(top.led(MARK_X.store, 1), 4, "the page change repaints the upper pane")
  context.clock.run_for(0.5)
  assert_equal(top.led(MARK_X.store, 1), 4)
  assert_equal(wide.led(MARK_X.store, 1), 15)
  params:set("v1_bookmark_1", 0.25)
  params:set("v1_buf_pos", 0.75)
  top.tap(1, 1)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-6, "the 256 recalls")
  params:set("v1_buf_pos", 0.75)
  wide.tap(1, 1)
  assert_near(params:get("v1_bookmark_1"), 0.75, 1e-6, "the 128h stores")
  wide.press(MARK_X.store, 1, 0)
end)

test("positions over its second side on a 256: a store held below stores the bookmark pressed below", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.positions, 1); bottom.show(pages.positions, 2)
  params:set("v1_buf_pos", 0.6)
  bottom.press(MARK_X.store, 1, 1)
  bottom.press(3, 1, 1); bottom.press(3, 1, 0)
  assert_near(params:get("v1_bookmark_3"), 0.6, 0.05, "the store held below stores the bookmark pressed below")
  bottom.press(MARK_X.store, 1, 0)
  -- a cell above jumps, and the bookmark below recalls it again
  top.tap(13, 1)
  assert_near(params:get("v1_buf_pos"), 0.75, 1e-9, "the cell above jumps")
  assert_equal(top.led(13, 1), 15, "and shows the playhead")
  bottom.tap(3, 1)
  assert_near(params:get("v1_buf_pos"), params:get("v1_bookmark_3"), 1e-9, "the bookmark below recalls it")
  assert_equal(bottom.led(3, 1), S.lib.positions.LEVELS.recalled, "lit as the last recalled")
  -- the top pane's page change leaves the bottom pane's held store
  bottom.press(MARK_X.store, 1, 1)
  top.show(pages.patterns)
  context.clock.run_for(0.2)
  params:set("v1_buf_pos", 0.3)
  bottom.press(4, 1, 1); bottom.press(4, 1, 0)
  assert_near(params:get("v1_bookmark_4"), 0.3, 0.05, "the store below still stores")
  bottom.press(MARK_X.store, 1, 0)
end)

test("a store key held on side 2 ends when its pane shows side 1, and the other pane's held store still stores", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local pages = S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.positions, 2); bottom.show(pages.positions, 2)
  top.press(MARK_X.store, 1, 1)
  bottom.press(MARK_X.store, 1, 1)
  -- the top pane's lit page key pressed again: its next side, side 1
  top.tap(strip_x(S, "upper", "page " .. pages.positions), 8)
  assert_equal(S.lib.grid_core.view(1, 1), "1:5:1:1", "the top pane shows side 1")
  context.clock.run_for(0.2)
  local bookmark = params:get("v1_bookmark_1")
  params:set("v1_buf_pos", 0.6)
  bottom.press(1, 1, 1); bottom.press(1, 1, 0)
  assert_near(params:get("v1_bookmark_1"), 0.6, 0.05, "a bookmark key below stores v1_bookmark_1")
  assert_true(math.abs(params:get("v1_bookmark_1") - bookmark) > 0.1, "a store, not the old value")
  bookmark = params:get("v1_bookmark_1")
  params:set("v1_buf_pos", 0.1)
  context.clear_engine_calls()
  top.press(MARK_X.store, 1, 0)  -- the top ST's release, after the side change
  assert_near(params:get("v1_bookmark_1"), bookmark, 1e-9, "the top pane's release stores nothing")
  assert_near(params:get("v1_buf_pos"), 0.1, 1e-9, "and jumps nowhere")
  bottom.press(MARK_X.store, 1, 0)
  assert_equal(S.lib.positions.strip_level(1, "store", 1), S.lib.positions.LEVELS.key_up, "both stores are up")
end)

-- A turn (Review Focus 4): a 128h turned upright is a new layout on the
-- port, which starts over (grid_core's forget_port), so page 5's held keys
-- end at the next tick, never act afterward, and nothing is stored
test("a 128h turned with a store key and a position cell held on page 5 ends both and stores nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local positions, pages, LEVELS = S.lib.positions, S.constants.GRID_PAGES, S.lib.positions.LEVELS
  -- the store key, held on side 2
  local wide = grid_pane(context, "128h")
  wide.show(pages.positions, 2)
  wide.press(MARK_X.store, 1, 1)
  assert_equal(positions.strip_level(1, "store"), LEVELS.key_down, "ST held")
  h.resize_grid(context, 1, 8, 16)
  context.clock.run_for(0.1)
  assert_equal(positions.strip_level(1, "store"), LEVELS.key_up, "the turn ends the store within a tick")
  local upright = grid_pane(context, "128v")
  upright.show(pages.positions, 2)
  params:set("v1_buf_pos", 0.6)
  upright.tap(1, 1)
  assert_near(params:get("v1_bookmark_1"), 0, 1e-9, "a bookmark key afterward recalls: nothing stored")
  assert_near(params:get("v1_buf_pos"), 0, 1e-9, "the recall jumped to bookmark 1")
  -- a position cell, held on side 1 (its jump waits for the bar, so the
  -- held cell shows at 11 away from the playhead)
  h.resize_grid(context, 1, 16, 8)
  wide = grid_pane(context, "128h")
  wide.show(pages.positions, 1)
  params:set("quantize_actions", 3)  -- bar
  wide.press(9, 1, 1)
  assert_equal(positions.grid_level(1, 9, 16, 1), LEVELS.held, "cell 9 held, at 11")
  h.resize_grid(context, 1, 8, 16)
  context.clock.run_for(0.1)
  assert_true(positions.grid_level(1, 9, 16, 1) ~= LEVELS.held, "the turn ends the held cell within a tick")
  params:set("quantize_actions", 1)
  upright = grid_pane(context, "128v")
  upright.show(pages.positions, 1)
  upright.tap(13, 1)
  assert_near(params:get("v1_loop_length"), 1, 1e-9, "a cell afterward makes no loop with it")
  assert_near(params:get("v1_loop_start"), 0, 1e-9)
end)

-- The 64's halves --------------------------------------------------------

test("the 64's halves show cells 1-8 and 9-16", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local cells = S.constants.GRID_PAGES.position_cells
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 1, 1)
  for x = 1, 8 do assert_equal(left.led(x, 1), S.lib.positions.grid_level(1, x, cells, 1), "left: cell " .. x) end
  assert_equal(left.shows(9, 1), false, "the left half shows no cell 9")
  left.tap(5, 1)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "left: cell 5 of 16")
  local right = grid_pane(context, "64 right")
  right.show(S.constants.GRID_PAGES.positions, 1, 2)
  for x = 9, 16 do assert_equal(right.led(x, 1), S.lib.positions.grid_level(1, x, cells, 1), "right: cell " .. x) end
  right.tap(9, 1)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "right: the first key is cell 9")
  -- side 2: the marks on the left half, the slots on the right
  right.show(S.constants.GRID_PAGES.positions, 2, 2)
  assert_equal(right.led(SLOT_X + 1, 1), S.lib.grid_core.record_level(1), "right: slot 1's record key")
  left.show(S.constants.GRID_PAGES.positions, 2, 1)
  assert_equal(left.led(MARK_X.store, 1), S.lib.positions.LEVELS.key_up, "left: voice 1's store")
end)

test("a cell held on the left half ends when the chooser shows the right half; a pair on the right sets a loop in cells 9-16", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local positions = S.lib.positions
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 1, 1)
  left.press(7, 1, 1)                    -- a loop anchor on the left
  left.press(1, 8, 1)                    -- NV, held: the chooser
  context.clock.run_for(0.6)
  left.tap(S.constants.GRID_PAGES.positions, 2)  -- positions' right half
  assert_equal(S.lib.grid_core.view(1, 1), "1:5:1:2", "the chooser shows the right half")
  left.press(1, 8, 0)
  local right = grid_pane(context, "64 right")
  right.press(15, 1, 0)                  -- the anchor's key comes up: column 7 is cell 15 now
  context.clock.run_for(0.1)
  right.tap(10, 1)
  assert_near(params:get("v1_loop_length"), 1, 1e-9, "no stale anchor made a loop")
  assert_near(params:get("v1_buf_pos"), 9 / 16, 1e-9, "a jump to cell 10")
  right.press(10, 1, 1); right.press(14, 1, 1)
  right.press(14, 1, 0); right.press(10, 1, 0)
  assert_near(params:get("v1_loop_start"), 9 / 16, 1e-9, "the loop from cell 10")
  assert_near(params:get("v1_loop_length"), 5 / 16, 1e-9, "to cell 14")
  assert_true(not positions.scan_held(1), "nothing held")
end)

-- #865: while the 64's chooser shows, a pane key's release goes to the
-- chooser and never reaches the page, and NV coming up with no pick keeps
-- the view. Opening the chooser invalidates the pane's presses, so each
-- positions record ends at the next key or tick
local function under_the_chooser(context, left, x, y)
  left.press(x, y, 1)                    -- the positions key held
  left.press(1, 8, 1)                    -- NV held
  context.clock.run_for(0.6)             -- the chooser opens
  left.press(x, y, 0)                    -- the key comes up under the chooser
  left.press(1, 8, 0)                    -- NV up, nothing picked: the same view
end

test("a position cell released under the chooser is ended when the chooser opens: the next tap jumps", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 1, 1)
  under_the_chooser(context, left, 3, 1)
  assert_equal(S.lib.grid_core.view(1, 1), "1:5:1:1", "the same view as before the chooser")
  left.tap(6, 1)
  assert_near(params:get("v1_loop_start"), 0, 1e-9, "no stale anchor: the loop start unchanged")
  assert_near(params:get("v1_loop_length"), 1, 1e-9, "and its length")
  assert_near(params:get("v1_buf_pos"), 5 / 16, 1e-9, "cell 6 jumped")
end)

test("HD released under the chooser leaves no scan hold", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local positions = S.lib.positions
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 2, 1)
  under_the_chooser(context, left, MARK_X.hold, 1)
  context.clock.run_for(0.2)             -- a playhead tick
  assert_equal(positions.scan_held(1), false, "every key is up: no scan hold")
  assert_equal(positions.holds_scan(1, "grid:1"), false, "the grid holds nothing")
  assert_equal(scan_hold_sent(context), 0, "scanHold 0 sent")
  assert_equal(left.led(MARK_X.hold, 1), positions.LEVELS.key_up, "HD dark again")
end)

test("a slice key released under the chooser stops", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local doubles = slice_double(S, 1, 20)
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 1, 1)
  under_the_chooser(context, left, 3, 1)
  assert_equal(doubles.plays[1].n, 3, "the key played slice 3")
  context.clock.run_for(0.2)             -- a playhead tick
  assert_equal(#doubles.offs, 1, "its note ended once")
  assert_equal(doubles.offs[1].voice, 1); assert_equal(doubles.offs[1].key, doubles.plays[1].note.key)
  left.tap(5, 1)
  assert_equal(#doubles.offs, 2, "the next key's slice plays and ends at its own release, nothing more")
end)

-- The real pane's still at a page change (a direct call's is a stand-in,
-- test/unit/positions_test.lua): the core invalidates the press, so the
-- held slice ends at the next tick and its late release ends nothing more
test("a held slice key ends when its pane shows another page, and its late release ends nothing more", function()
  each_arrangement(function(context, S, pane, arrangement)
    local doubles = slice_double(S, 2, 20)
    local first = shown_columns(pane)
    pane.press(first + 4, 2, 1)
    assert_equal(doubles.plays[1].n, first + 4, arrangement .. ": the key plays its slice")
    pane.show(S.constants.GRID_PAGES.patterns)
    context.clock.run_for(0.1)            -- a playhead tick
    assert_equal(#doubles.offs, 1, arrangement .. ": the page change ends it")
    assert_equal(doubles.offs[1].key, doubles.plays[1].note.key, arrangement .. ": the slice it played")
    pane.press(first + 4, 2, 0)           -- the release, on another page now
    assert_equal(#doubles.offs, 1, arrangement .. ": and its late release ends nothing more")
  end)
end)

test("a 256 with both panes on positions keeps each pane's keys apart", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local positions, pages = S.lib.positions, S.constants.GRID_PAGES
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(pages.positions, 1); bottom.show(pages.positions, 2)
  -- a cell held above lives through the lower pane's page change
  top.press(5, 1, 1)
  bottom.press(MARK_X.hold, 1, 1)
  bottom.show(pages.patterns)
  context.clock.run_for(0.2)
  assert_equal(positions.scan_held(1), false, "the lower pane's page change ends its hold")
  top.press(9, 1, 1)
  assert_near(params:get("v1_loop_start"), 0.25, 1e-9, "the held cell above and cell 9 set the loop")
  assert_near(params:get("v1_loop_length"), 0.3125, 1e-9)
  top.press(9, 1, 0); top.press(5, 1, 0)
  -- HD held in both panes: each pane's release or page change is its own
  top.show(pages.positions, 2); bottom.show(pages.positions, 2)
  top.press(MARK_X.hold, 2, 1); bottom.press(MARK_X.hold, 2, 1)
  bottom.press(MARK_X.hold, 2, 0)
  context.clock.run_for(0.2)
  assert_equal(positions.scan_held(2), true, "the lower release leaves the upper pane's hold")
  bottom.press(MARK_X.hold, 2, 1)
  top.show(pages.faders)
  context.clock.run_for(0.2)
  assert_equal(positions.scan_held(2), true, "the upper page change leaves the lower pane's hold")
  bottom.press(MARK_X.hold, 2, 0)
  assert_equal(positions.scan_held(2), false, "the last key up ends it")
  top.press(MARK_X.hold, 2, 0)  -- the upper key's release, on another page now
  assert_equal(positions.scan_held(2), false, "and nothing comes back")
end)

test("64: the positions view is per port", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local one = grid_pane(context, "64 left")
  local two = grid_pane(context, "64 left", {port = 2})
  one.show(S.constants.GRID_PAGES.positions, 1, 1)
  two.show(S.constants.GRID_PAGES.patterns, 1, 1)
  S.lib.grid_core.set_half(2, 1, 2)
  assert_equal(S.lib.grid_core.view(1, 1), "1:5:1:1", "port 1 shows positions' left half")
  assert_equal(S.lib.grid_core.view(2, 1), "1:1:1:2", "port 2 its own steps' right half")
end)

test("64: a hold key whose release comes after the view switched leaks nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local positions = S.lib.positions
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.positions, 2, 1)
  left.press(MARK_X.hold, 1, 1)  -- scan hold down
  assert_true(positions.scan_held(1), "held")
  left.show(S.constants.GRID_PAGES.patterns, 1, 1)  -- the view leaves positions
  left.press(MARK_X.hold, 1, 0)
  context.clock.run_for(0.1)
  assert_true(not positions.scan_held(1), "no stuck scan hold")
end)

test("64: a hold in the step views keeps working and never reaches positions", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local calls = 0
  local original_strip, original_grid = S.lib.positions.strip_key, S.lib.positions.grid_key
  S.lib.positions.strip_key = function() calls = calls + 1 end
  S.lib.positions.grid_key = function() calls = calls + 1 end
  local left = grid_pane(context, "64 left")
  left.show(S.constants.GRID_PAGES.patterns, 1, 1)
  local shown = {}
  local function look() shown[#shown + 1] = tostring(shown_step_editor()) end
  left.press(3, 2, 1); context.clock.run_for(0.6); look()
  left.press(3, 2, 0); look()
  left.press(6, 3, 1); context.clock.run_for(0.6); look()
  left.press(6, 3, 0); look()
  S.lib.positions.strip_key, S.lib.positions.grid_key = original_strip, original_grid
  assert_equal(calls, 0, "no positions call from the step views")
  assert_equal(table.concat(shown, ","), "2 3 1,nil,3 6 1,nil", "each hold opened the step editor, each release closed it")
end)

test("the slice rows repaint from the playhead clock when a slice starts or ends", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local doubles = slice_double(S, 1, 20)
  local pane = grid_pane(context, "256 top")
  pane.show(S.constants.GRID_PAGES.positions, 1)
  assert_equal(pane.led(3, 1), 9, "slice 3 exists")
  local before = S.lib.positions.display_signature()
  doubles.sounding.other = {voice = 1, n = 3}
  assert_true(S.lib.positions.display_signature() ~= before, "the signature sees a slice start")
  context.clock.run_for(0.2)
  assert_equal(pane.led(3, 1), 15, "the clock repainted it playing")
  doubles.sounding.other = nil
  context.clock.run_for(0.2)
  assert_equal(pane.led(3, 1), 9, "and ended")
  S.lib.positions.strip_key(1, 1, 2, 1); S.lib.positions.strip_key(1, 1, 2, 0)
  context.clock.run_for(0.2)
  assert_equal(pane.led(5, 1), 0, "a bank change shows")
  pane.show(S.constants.GRID_PAGES.positions, 2)
  assert_equal(pane.led(2, 1), 15, "and its key, on side 2")
end)


-- #876: a jump or a two-key loop that waits for its bar blinks the cell
-- pressed (a loop's second key) between the waiting levels, as a waiting
-- bookmark does (#593); the bar's jump shows steady
test("a position cell blinks while its jump or loop waits", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local LEVELS = S.lib.positions.LEVELS
  local tick = 1 / S.constants.PLAYHEADS.update_hz
  local pane = grid_pane(context, "256 top")
  pane.show(S.constants.GRID_PAGES.positions)
  local function seen_over(ticks, x, y)
    local seen = {}
    for _ = 1, ticks do
      context.clock.run_for(tick)
      seen[pane.led(x, y)] = true
    end
    return seen
  end
  params:set("quantize_actions", 3)  -- bar
  context.clock.run_for((1.5 - clock.get_beats()) * clock.get_beat_sec())
  pane.tap(9, 1)
  local detail = S.lib.quantize.waiting_detail("position1")
  assert_true(detail and detail.voice == 1 and detail.cell == 9, "the jump keeps its voice and cell")
  local seen = seen_over(12, 9, 1)
  assert_true(seen[LEVELS.waiting_high] and seen[LEVELS.waiting_low], "the jump's cell blinks")
  assert_true(not seen_over(4, 9, 2)[LEVELS.waiting_low], "voice 2's cell does not")
  context.clock.run_for((4.05 - clock.get_beats()) * clock.get_beat_sec())
  seen = seen_over(8, 9, 1)
  assert_true(seen[LEVELS.playhead] and not seen[LEVELS.waiting_low], "the jump landed: the head, steady")
  -- a loop: cell 3 held, cell 12 pressed
  pane.press(3, 2, 1); pane.press(12, 2, 1)
  pane.press(12, 2, 0); pane.press(3, 2, 0)
  detail = S.lib.quantize.waiting_detail("position2")
  assert_true(detail and detail.voice == 2 and detail.cell == 12, "the loop keeps its voice and pressed cell")
  seen = seen_over(12, 12, 2)
  assert_true(seen[LEVELS.waiting_high] and seen[LEVELS.waiting_low], "the loop's cell blinks")
  S.lib.quantize.cancel("position2")
end)


-- #876 review (the controller's ruling): one redraw rule for every blink,
-- #593's: a cell's or a scene's wait repaints no grid while no pane shows
-- that page; once a pane shows the positions page's cells, the cell's wait
-- repaints at each phase
test("a cell or scene wait with no pane on its page repaints no grid", function()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  local tick = 1 / S.constants.PLAYHEADS.update_hz
  local pages = S.constants.GRID_PAGES
  local pane = grid_pane(context, "256 top")
  pane.show(pages.patterns)
  local device = pane.device
  params:set("quantize_actions", 3)  -- bar
  local function repaints_over(ticks)
    local before = device.refresh_count
    context.clock.run_for(tick * ticks)
    return device.refresh_count - before
  end
  assert_equal(repaints_over(8), 0, "nothing waits: no repaint")
  -- just past a bar, so the next lies two seconds ahead (both windows below)
  local beats = clock.get_beats()
  context.clock.run_for((math.floor(beats / 4) * 4 + 4.1 - beats) * clock.get_beat_sec())
  S.lib.positions.grid_key(1, 1, 9, pages.position_cells, 1); S.lib.positions.grid_key(1, 1, 9, pages.position_cells, 0)
  S.lib.quantize.schedule("scene", function() end, "S2", 2)
  assert_equal(S.lib.positions.waiting_cell(1), 9, "the jump waits on cell 9")
  assert_equal(S.lib.quantize.waiting_detail("scene"), 2, "the recall waits on scene 2")
  assert_equal(repaints_over(8), 0, "no pane shows positions or scenes: the waits repaint no grid")
  pane.show(pages.positions)
  assert_true(repaints_over(8) >= 2, "a pane shows the cells: the wait repaints at each phase")
  assert_equal(S.lib.positions.waiting_cell(1), 9, "and the jump still waits")
  S.lib.quantize.cancel("scene"); S.lib.quantize.cancel("position1")
end)


-- #876 review, round 2: the FZ key is the voices page's alone, so a
-- freeze wait repaints no grid while no pane shows voices; once a pane
-- does, it repaints at each phase. (The play key is on every layout's
-- strip, shown whatever page a pane shows, so its wait always counts)
test("a freeze wait with no pane on voices repaints no grid", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local tick = 1 / S.constants.PLAYHEADS.update_hz
  local pages = S.constants.GRID_PAGES
  local pane = grid_pane(context, "128h")
  pane.show(pages.patterns)
  local device = pane.device
  params:set("quantize_actions", 3)  -- bar
  local function repaints_over(ticks)
    local before = device.refresh_count
    context.clock.run_for(tick * ticks)
    return device.refresh_count - before
  end
  assert_equal(repaints_over(8), 0, "nothing waits: no repaint")
  -- just past a bar, so the next lies two seconds ahead (both windows below)
  local beats = clock.get_beats()
  context.clock.run_for((math.floor(beats / 4) * 4 + 4.1 - beats) * clock.get_beat_sec())
  S.lib.freeze.toggle_quantized(2)
  assert_true(S.lib.quantize.waiting("freeze2"), "voice 2's set waits")
  assert_equal(repaints_over(8), 0, "no pane shows voices: the wait repaints no grid")
  pane.show(pages.voices)
  assert_true(repaints_over(8) >= 2, "a pane shows voices: the wait repaints at each phase")
  assert_true(S.lib.quantize.waiting("freeze2"), "and the set still waits")
  S.lib.quantize.cancel("freeze2")
end)

-- #1094: real grid events, slice regions and allocator records.
local function slice_panes()
  local context = load_strata(); finish_startup(context)
  local S = buffer_voices(context)
  assert_true(S.lib.samples.set(1, "frames", 16 * 48000))
  assert_true(S.lib.samples.set(1, "rate", 48000))
  assert_true(S.lib.samples.set(1, "mode", 2))
  assert_true(S.lib.samples.set(1, "count", 32))
  assert_true(S.lib.slices.make(1))
  params:set("v1_slices", 3)
  params:set("v1_note_cap", 3)
  context.clock.run_for(0.1) -- let the buffer bind settle before playing
  local top = grid_pane(context, "256 top")
  local bottom = grid_pane(context, "256 bottom")
  top.show(S.constants.GRID_PAGES.positions)
  bottom.show(S.constants.GRID_PAGES.positions)
  return context, S, top, bottom
end

local function bank_two(S, bottom)
  bottom.show(S.constants.GRID_PAGES.positions, 2)
  bottom.tap(2, 1)
  bottom.show(S.constants.GRID_PAGES.positions, 1)
end

local function playing(S)
  return table.concat(S.lib.slices.playing(1), ",")
end

for _, bottom_first in ipairs({false, true}) do
  local order = bottom_first and "bottom first" or "top first"
  for _, bottom_cell in ipairs({4, 5}) do
    test("banked slices at bottom cell " .. bottom_cell .. " release " .. order, function()
      local _, S, top, bottom = slice_panes()
      top.press(4, 1, 1)
      bank_two(S, bottom)
      bottom.press(bottom_cell, 1, 1)
      local other = bottom_cell == 4 and "20" or "21"
      assert_equal(playing(S), "4," .. other)
      if bottom_first then
        bottom.press(bottom_cell, 1, 0)
        assert_equal(playing(S), "4")
        top.press(4, 1, 0)
      else
        top.press(4, 1, 0)
        assert_equal(playing(S), other)
        bottom.press(bottom_cell, 1, 0)
      end
      assert_equal(S.lib.notes.held(1), 0)
    end)
  end

  test("two panes retrigger one slice until both release, " .. order, function()
    local context, S, top, bottom = slice_panes()
    top.press(4, 1, 1)
    context.clear_engine_calls()
    bottom.press(4, 1, 1)
    assert_equal(#context.calls_named("retrigger"), 1, "the second press is audible")
    assert_equal(S.lib.notes.held(1), 1)
    local first, last = top, bottom
    if bottom_first then first, last = bottom, top end
    first.press(4, 1, 0)
    assert_equal(playing(S), "4", "the other pane still holds the slice")
    last.press(4, 1, 0)
    assert_equal(S.lib.notes.held(1), 0)
  end)
end

test("a quantized slice retrigger follows the last physical holder", function()
  local context, S, top, bottom = slice_panes()
  params:set("quantize_actions", 2)
  top.press(4, 1, 1)
  bottom.press(4, 1, 1)
  bottom.press(4, 1, 0)
  assert_true(S.lib.quantize.waiting("position1"), "the top press still wants the beat")
  context.clock.run_for(clock.get_beat_sec())
  assert_equal(playing(S), "4")
  bottom.press(4, 1, 1) -- sounding with another retrigger pending
  top.press(4, 1, 0)
  bottom.press(4, 1, 0)
  assert_true(not S.lib.quantize.waiting("position1"), "the last release cancels the retrigger")
  assert_equal(S.lib.notes.held(1), 0, "and ends the sounding slice")
end)

test("two released one-shot keys play their shared pending slice once to its end", function()
  local context, S, top, bottom = slice_panes()
  params:set("v1_scan_mode", 3)
  params:set("v1_buf_scan", 1)
  params:set("quantize_actions", 2)
  context.clear_engine_calls()
  top.press(4, 1, 1)
  bottom.press(4, 1, 1)
  bottom.press(4, 1, 0)
  top.press(4, 1, 0)
  context.clock.run_for(clock.get_beat_sec())
  assert_equal(playing(S), "4")
  assert_equal(#context.calls_named("retrigger"), 1)
  context.clock.run_for(0.6)
  assert_equal(S.lib.notes.held(1), 0)
end)

test("two grids hold separate slice notes through pane changes, unplug and cleanup", function()
  local context, S, top, bottom = slice_panes()
  local other = grid_pane(context, "128h", {port = 2})
  other.show(S.constants.GRID_PAGES.positions)
  top.press(4, 1, 1)
  bottom.press(4, 1, 1)
  other.press(4, 1, 1)
  assert_equal(S.lib.notes.held(1), 2)
  bottom.show(S.constants.GRID_PAGES.patterns)
  bottom.press(1, 2, 1)
  context.clock.run_for(0.4)
  assert_equal(shown_step_editor(), "2 1 1")
  assert_equal(S.lib.notes.held(1), 2, "changing the lower pane leaves the top key and other grid")
  context.grid.unplug(1)
  context.clock.run_for(0.1)
  assert_equal(S.lib.notes.held(1), 1)
  assert_true(S.lib.notes.find(1, "grid", 204) ~= nil, "the other device still owns its slice")
  cleanup()
  assert_equal(S.lib.notes.held(1), 0)
end)

for _, loss in ipairs({"steal", "source change"}) do
  test("a new slice press after a " .. loss .. " releases independently of the old holder", function()
    local context, S, top, bottom = slice_panes()
    params:set("v1_note_cap", 2)
    top.press(3, 1, 1) -- own note
    top.press(4, 1, 1) -- extra slot
    if loss == "steal" then
      context.clock.run_for(0.1) -- the extra slot is old enough to steal
      top.press(5, 1, 1)
    else
      params:set("v1_source", 1)
      params:set("v1_source", 2)
    end
    assert_equal(S.lib.notes.find(1, "grid", 104), nil, "the original extra note ended")
    bottom.press(4, 1, 1)
    assert_true(S.lib.notes.find(1, "grid", 104) ~= nil, "the lower pane plays a fresh note")
    bottom.press(4, 1, 0)
    assert_equal(S.lib.notes.find(1, "grid", 104), nil, "the upper key cannot hold the fresh note")
    top.press(4, 1, 0)
    top.press(5, 1, 0)
    top.press(3, 1, 0)
    assert_equal(S.lib.notes.held(1), 0)
  end)
end

test("a retrigger whose slice disappeared still releases the earlier sounding note", function()
  local context, S, top, bottom = slice_panes()
  top.press(4, 1, 1)
  params:set("quantize_actions", 2)
  bottom.press(4, 1, 1)
  assert_true(S.lib.slices.set_markers(1, {0}, true))
  context.clock.run_for(clock.get_beat_sec())
  assert_true(S.lib.notes.find(1, "grid", 104) ~= nil, "the earlier note is still held")
  top.press(4, 1, 0)
  bottom.press(4, 1, 0)
  assert_equal(S.lib.notes.held(1), 0)
end)

end

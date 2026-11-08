-- test/unit/pages_seq_test.lua
-- The SEQ page (lib/pages/seq.lua): the seven pattern rows, the step
-- cursor, E2/E3/K2/K3 and their ALT layer, the tempo in the header; its
-- rings are in arc_pages_test.lua
-- Run alone: lua test/run.lua pages_seq

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, hint_text, tap, assert_screen_layout = h.show_page, h.hint_text, h.tap, h.assert_screen_layout

-- The layout the brief fixes: cells 4x4 px, 6 px apart from x 10; rows 6 px
-- apart from y 13
local CELLS_X, CELL_SPACING, CELL_SIZE, ROWS_Y, ROW_SPACING = 10, 6, 4, 13, 6

local function cell_x(step) return CELLS_X + (step - 1) * CELL_SPACING end
local function row_y(voice_idx) return ROWS_Y + (voice_idx - 1) * ROW_SPACING end

-- The rect drawn at x, y with size w x h (nil if none)
local function rect_at(context, x, y, w, h)
  for _, rect in ipairs(context.screen.rects) do
    if rect.x == x and rect.y == y and rect.w == w and rect.h == h then return rect end
  end
end

local function cell(context, voice_idx, step)
  return rect_at(context, cell_x(step), row_y(voice_idx), CELL_SIZE, CELL_SIZE)
end

-- The 6x6 cursor outline around voice_idx's step
local function cursor_rect(context, voice_idx, step)
  return rect_at(context, cell_x(step) - 1, row_y(voice_idx) - 1, CELL_SIZE + 2, CELL_SIZE + 2)
end

local function header_text(context, text)
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == 8 and entry.text == text then return entry end
  end
end

local function started_on_seq()
  local context = load_strata(); finish_startup(context)
  show_page("SEQ")
  return context, local_value("S")
end

test("SEQ draws seven rows of sixteen cells at their levels", function()
  local context, S = started_on_seq()
  S.patterns[2][5] = 9; S.patterns[2][6] = 1; S.patterns[2][7] = 0
  S.cursors.seq_step = 1; S.selected_voice = 1
  redraw()
  local nine = cell(context, 2, 5)
  assert_true(nine and nine.x == 10 + 4 * 6, "step 5 at x 34")
  assert_equal(nine.filled, true, "a set step is filled"); assert_equal(nine.level, 9, "at its level")
  local one = cell(context, 2, 6)
  assert_equal(one.filled, true, "a level-1 step is filled"); assert_equal(one.level, 1)
  local empty = cell(context, 2, 7)
  assert_equal(empty.filled, false, "an empty step is an outline"); assert_equal(empty.level, 1)
  local cells = 0
  for voice_idx = 1, 7 do
    for step = 1, 16 do
      if cell(context, voice_idx, step) then cells = cells + 1 end
    end
    -- the voice's number at x 0 and its run state at the right, on the row
    local number, state
    for _, entry in ipairs(context.screen.texts) do
      if entry.y > row_y(voice_idx) and entry.y <= row_y(voice_idx) + ROW_SPACING then
        if entry.x == 0 and entry.text == tostring(voice_idx) then number = entry end
        if entry.x == 127 and entry.align == "right" then state = entry.text end
      end
    end
    assert_true(number, "voice " .. voice_idx .. "'s number at x 0")
    assert_equal(state, S.voices[voice_idx].active and "+" or "-", "voice " .. voice_idx .. "'s run state")
  end
  assert_equal(cells, 7 * 16, "seven rows of sixteen cells")
  local cursor = cursor_rect(context, 1, 1)
  assert_true(cursor, "the cursor: a 6x6 rect around voice 1, step 1")
  assert_equal(cursor.filled, false, "an outline"); assert_equal(cursor.level, 15, "at level 15")
  assert_screen_layout(context, "SEQ")
end)

test("E2 moves the step, ALT+E2 the voice row, and the selected voice follows", function()
  local context, S = started_on_seq()
  S.selected_voice = 1
  enc(2, 3); assert_equal(S.cursors.seq_step, 4, "E2 moves the step")
  enc(2, 40); assert_equal(S.cursors.seq_step, 16, "and stops at the last")
  enc(2, -40); assert_equal(S.cursors.seq_step, 1, "and at the first")
  enc(2, 2)
  key(1, 1); enc(2, 2); key(1, 0)
  assert_equal(S.selected_voice, 3, "ALT+E2 moves to voice 3's row")
  assert_equal(S.cursors.seq_step, 3, "the step stays")
  key(1, 1); enc(2, 20); key(1, 0)
  assert_equal(S.selected_voice, 7, "and stops at the last voice")
  redraw()
  assert_true(cursor_rect(context, 7, 3), "the cursor follows to voice 7's row")
  show_page("MAIN")
  assert_equal(local_value("voice_list").index, 7, "MAIN's list follows the selected voice")
end)

test("E3 sets the step level from 0 to 15 and K3 toggles it at 15", function()
  local _, S = started_on_seq()
  S.selected_voice = 3; S.cursors.seq_step = 5
  enc(3, 1); assert_equal(S.patterns[3][5], 1, "one level per detent")
  enc(3, 20); assert_equal(S.patterns[3][5], 15, "up to MAX_STEP_LEVEL")
  enc(3, -20); assert_equal(S.patterns[3][5], 0, "down to 0 (off)")
  tap(3); assert_equal(S.patterns[3][5], 15, "K3 turns it on at 15")
  enc(3, -6); assert_equal(S.patterns[3][5], 9)
  tap(3); assert_equal(S.patterns[3][5], 0, "K3 turns a set step off")
  for voice_idx = 1, 7 do
    for step = 1, 16 do
      if not (voice_idx == 3 and step == 5) then
        assert_equal(S.patterns[voice_idx][step], 0, "only the cursor's step changes")
      end
    end
  end
end)

test("K2 plays and stops; the playing column is brighter", function()
  local context, S = started_on_seq()
  S.patterns[1][4] = 9
  S.patterns[1][1] = 15
  tap(2)
  assert_true(S.pattern_playing, "K2 plays")
  -- run the pattern clock until step 4 has played: it is the playing column
  while S.pattern_position ~= 5 do context.clock.advance_until(S.pattern_clock) end
  redraw()
  local nine = cell(context, 1, 4)
  assert_equal(nine.filled, true); assert_equal(nine.level, 13, "a level-9 cell in the playing column at 13")
  local empty = cell(context, 2, 4)
  assert_equal(empty.filled, false); assert_equal(empty.level, 4, "an empty one as an outline at 4")
  assert_equal(cell(context, 1, 1).level, 15, "a level-15 cell elsewhere stays 15")
  assert_equal(cell(context, 2, 5).level, 1, "the next column is not the playing one")
  assert_equal(hint_text(context), "K2:stop K3:step E3:level", "K2:stop while playing")
  tap(2)
  assert_true(not S.pattern_playing, "K2 stops")
  redraw()
  assert_equal(cell(context, 1, 4).level, 9, "no playing column once stopped")
  assert_equal(cell(context, 2, 4).level, 1)
end)

test("while the patterns play SEQ redraws the screen every frame and never the arc", function()
  local context, S = started_on_seq()
  local arc_hardware = context.arc.plug(1)
  h.next_frame(context)
  tap(2)
  h.next_frame(context)  -- the press's own redraw
  local counter = h.count_screen_draws()
  local arc_refreshes = arc_hardware.refresh_count
  for _ = 1, 3 do h.next_frame(context) end
  counter.restore()
  assert_equal(counter.screen, 3, "the screen draws each frame while playing")
  assert_equal(arc_hardware.refresh_count, arc_refreshes, "the arc does not")
  -- the playhead moves
  S.patterns[1][4] = 9
  local before = S.pattern_position
  context.clock.advance_until(S.pattern_clock)
  assert_true(S.pattern_position ~= before, "the pattern clock advances")
  -- stopped: no extra redraws
  tap(2)
  h.next_frame(context); h.next_frame(context)
  counter = h.count_screen_draws()
  h.next_frame(context); h.next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "stopped: no redraw until something changes")
end)

test("SEQ playing while another page shows adds no redraws", function()
  local context, S = started_on_seq()
  tap(2)
  show_page("MAIN")
  h.next_frame(context); h.next_frame(context)
  local counter = h.count_screen_draws()
  h.next_frame(context); h.next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "patterns playing, SEQ not shown")
end)

test("ALT+K2 clears and ALT+K3 randomizes the voice's pattern", function()
  local _, S = started_on_seq()
  S.selected_voice = 4
  for step = 1, 16 do S.patterns[4][step] = 7; S.patterns[5][step] = 3 end
  key(1, 1); tap(2); key(1, 0)
  for step = 1, 16 do
    assert_equal(S.patterns[4][step], 0, "ALT+K2 clears voice 4's step " .. step)
    assert_equal(S.patterns[5][step], 3, "and leaves voice 5's")
  end
  math.randomseed(1)
  key(1, 1); tap(3); key(1, 0)
  local set = 0
  for step = 1, 16 do
    local level = S.patterns[4][step]
    assert_true(level == 0 or (level >= 8 and level <= 15), "a randomized level: " .. level)
    if level > 0 then set = set + 1 end
    assert_equal(S.patterns[5][step], 3, "voice 5 untouched")
  end
  assert_true(set > 0, "ALT+K3 sets some steps")
  assert_true(not S.pattern_playing, "the ALT keys never start the transport")
end)

test("ALT+E3 changes the tempo and the header shows it", function()
  local context, S = started_on_seq()
  params:set("tempo", 120)
  S.cursors.seq_step = 2
  key(1, 1); enc(3, 2); key(1, 0)
  assert_equal(params:get("tempo"), 122, "ALT+E3 steps the tempo")
  assert_equal(S.patterns[S.selected_voice][2], 0, "and leaves the step's level")
  redraw()
  local shown = header_text(context, "122 bpm")
  assert_true(shown, "the header shows the tempo"); assert_equal(shown.x, 79, "at x 79")
  assert_equal(S.registry.pages[S.constants.UI_PAGES.index.SEQ].header_status(), "122 bpm")
  params:set("tempo", 300); redraw()
  assert_true(header_text(context, "300 bpm"), "300 bpm")
  assert_screen_layout(context, "SEQ at 300 bpm")
end)

test("the arc button plays and stops the patterns", function()
  local _, S = started_on_seq()
  local record = S.registry.pages[S.constants.UI_PAGES.index.SEQ]
  record.arc_button()
  assert_true(S.pattern_playing, "the button plays")
  record.arc_button()
  assert_true(not S.pattern_playing, "and stops")
end)

test("pattern edits on SEQ reach the grid", function()
  local context, S = started_on_seq()
  local device = context.grid.plug(1, 16, 8)
  S.selected_voice = 2; S.cursors.seq_step = 6
  local function led() return device:get_led(6, 2) end  -- 128h: step column, voice row
  enc(3, 5); assert_equal(led(), 5, "E3's level on the grid")
  tap(3); assert_equal(led(), 0, "K3 off")
  tap(3); assert_equal(led(), 15, "K3 on")
  key(1, 1); tap(2); key(1, 0); assert_equal(led(), 0, "ALT+K2 clear")
  math.randomseed(3)
  key(1, 1); tap(3); key(1, 0)
  for step = 1, 16 do
    assert_equal(device:get_led(step, 2), S.patterns[2][step], "ALT+K3's step " .. step .. " on the grid")
  end
end)

test("SEQ hints", function()
  local context, S = started_on_seq()
  assert_equal(hint_text(context), "K2:play K3:step E3:level", "stopped")
  tap(2); redraw()
  assert_equal(hint_text(context), "K2:stop K3:step E3:level", "playing")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:clr K3:rand E3:bpm", "ALT")
  key(1, 0); tap(2)
  assert_true(not S.pattern_playing)
end)

test("SEQ's playing column is the sequencer's sounding step, the one the grid lights (#113)", function()
  local context, S = started_on_seq()
  local device = context.grid.plug(1, 16, 8)
  S.patterns[1][2] = 9
  tap(2)  -- plays step 1 at once
  redraw()
  assert_equal(cell(context, 2, 1).level, 4, "just started: column 1 plays")
  assert_equal(cell(context, 2, 16).level, 1, "never the last column")
  h.wake(context, "pattern_clock")  -- step 2 plays
  context.grid.press(1, 3, 3, 1); context.grid.press(1, 3, 3, 0)  -- a key press between steps redraws the grid
  redraw()
  assert_equal(cell(context, 1, 2).level, 13, "SEQ: column 2 plays")
  assert_equal(device:get_led(2, 1), 15, "the grid lights the same step")
  assert_equal(device:get_led(2, 2), 4, "an empty step in that column at 4")
  assert_equal(device:get_led(3, 2), 0, "and not the next step")
  assert_equal(cell(context, 2, 3).level, 1, "SEQ: column 3 does not play either")
  -- no sounding step: no playing column, though the transport runs
  S.pattern_sounding_step = nil
  redraw()
  assert_equal(cell(context, 1, 2).level, 9, "nothing sounding: no playing column")
  tap(2)
end)

end

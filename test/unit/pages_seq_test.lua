-- test/unit/pages_seq_test.lua
-- The SEQ page (lib/pages/seq.lua): the seven pattern rows, the step
-- cursor, E2/E3/K2/K3 and their ALT layer, the tempo in the header; its
-- rings are in arc_pages_test.lua
-- Run alone: lua test/run.lua pages_seq

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
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

test("while the norns menu is open the playing SEQ page never draws itself", function()
  local context, S = started_on_seq()
  local arc_hardware = context.arc.plug(1)
  local record = S.registry.pages[S.constants.UI_PAGES.index.SEQ]
  local page_draws, real_draw = 0, record.draw
  record.draw = function(...) page_draws = page_draws + 1; return real_draw(...) end
  tap(2)
  h.next_frame(context)
  assert_true(S.pattern_playing, "playing")
  assert_equal(page_draws, 1, "the frame draws SEQ")
  _menu.set_mode(true)
  -- set_mode(true) has put norns.none in the global redraw, as norns does: a
  -- stand-in that draws nothing counts the calls
  local script_redraw = redraw
  local swapped_calls = 0
  redraw = function() swapped_calls = swapped_calls + 1 end
  page_draws = 0
  local arc_refreshes = arc_hardware.refresh_count
  for _ = 1, 3 do h.next_frame(context) end
  assert_equal(swapped_calls, 3, "each frame calls the global redraw, norns.none in the menu")
  assert_equal(page_draws, 0, "the page never draws while the menu is open")
  assert_equal(arc_hardware.refresh_count, arc_refreshes, "and the arc gets no extra frames")
  assert_true(S.pattern_playing, "the patterns keep playing")
  -- the menu closes: set_mode(false) puts the script's redraw back and calls it
  redraw = script_redraw
  _menu.set_mode(false)
  page_draws = 0
  for _ = 1, 2 do h.next_frame(context) end
  assert_equal(page_draws, 2, "back from the menu SEQ draws every frame again")
  record.draw = real_draw
  tap(2)
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

test("ALT+K3 clears the voice's pattern and ALT+K2 randomizes it at levels 8-15", function()
  local _, S = started_on_seq()
  S.selected_voice = 4
  for step = 1, 16 do S.patterns[4][step] = 7; S.patterns[5][step] = 3 end
  key(1, 1); tap(3); key(1, 0)
  for step = 1, 16 do
    assert_equal(S.patterns[4][step], 0, "ALT+K3 clears voice 4's step " .. step)
    assert_equal(S.patterns[5][step], 3, "and leaves voice 5's")
  end
  math.randomseed(1)
  key(1, 1); tap(2); key(1, 0)
  local set = 0
  for step = 1, 16 do
    local level = S.patterns[4][step]
    assert_true(level == 0 or (level >= 8 and level <= 15), "a randomized level: " .. level)
    if level > 0 then set = set + 1 end
    assert_equal(S.patterns[5][step], 3, "voice 5 untouched")
  end
  assert_true(set > 0, "ALT+K2 sets some steps")
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
  key(1, 1); tap(3); key(1, 0); assert_equal(led(), 0, "ALT+K3 clear")
  math.randomseed(3)
  key(1, 1); tap(2); key(1, 0)
  for step = 1, 16 do
    assert_equal(device:get_led(step, 2), S.patterns[2][step], "ALT+K2's step " .. step .. " on the grid")
  end
end)

test("a SEQ pattern edit requests one redraw, enc's or key's own", function()
  local context, S = started_on_seq()
  S.selected_voice = 2; S.cursors.seq_step = 6
  local requests, real = 0, request_redraw
  request_redraw = function() requests = requests + 1; real() end
  local function count(action)
    requests = 0
    action()
    return requests
  end
  local grids = 0
  local real_grid = grid_redraw
  grid_redraw = function() grids = grids + 1; real_grid() end
  assert_equal(count(function() enc(3, 2) end), 1, "E3")
  assert_equal(count(function() key(3, 1) end), 1, "K3")
  key(3, 0)
  key(1, 1)
  assert_equal(count(function() key(3, 1) end), 1, "ALT+K3")
  key(3, 0)
  assert_equal(count(function() key(2, 1) end), 1, "ALT+K2's press")
  assert_true(count(function() key(2, 0) end) >= 1, "ALT+K2's release, where the randomize happens, requests a redraw")
  key(1, 0)
  grid_redraw = real_grid
  request_redraw = real
  assert_true(grids >= 4, "each edit still redraws the grid")
end)

local function steps_of(S, voice_idx)
  local steps = {}
  for step = 1, 16 do steps[step] = S.patterns[voice_idx][step] end
  return steps
end

local function same_steps(a, b)
  for step = 1, 16 do if a[step] ~= b[step] then return false end end
  return true
end

test("SEQ's ALT+K2 randomizes the selected voice's pattern on release; ALT+K3 clears it (#557)", function()
  local _, S = started_on_seq()
  S.selected_voice = 3
  math.randomseed(5)
  key(1, 1); key(2, 1)
  local empty = true
  for step = 1, 16 do if S.patterns[3][step] ~= 0 then empty = false end end
  assert_true(empty, "the press alone changes nothing")
  key(2, 0)
  local on = 0
  for step = 1, 16 do if S.patterns[3][step] > 0 then on = on + 1 end end
  assert_true(on > 0, "the release randomized")
  for voice_idx = 1, 7 do
    if voice_idx ~= 3 then
      for step = 1, 16 do assert_equal(S.patterns[voice_idx][step], 0, "other voices stay") end
    end
  end
  key(3, 1); key(3, 0); key(1, 0)
  for step = 1, 16 do assert_equal(S.patterns[3][step], 0, "ALT+K3 clears") end
end)

test("a quick ALT+K2 within 5 s restores the exact old steps (#557)", function()
  local _, S = started_on_seq()
  S.selected_voice = 2
  S.patterns[2][1] = 7; S.patterns[2][9] = 12
  local old = steps_of(S, 2)
  key(1, 1); tap(2)
  assert_true(not same_steps(steps_of(S, 2), old), "randomized")
  tap(2)
  assert_true(same_steps(steps_of(S, 2), old), "the second press undid it")
  key(1, 0)
end)

test("a step edit, ALT+K3 and the other edits end the pattern undo (#557)", function()
  local context, S = started_on_seq()
  S.selected_voice = 2; S.cursors.seq_step = 4
  local mutation = S.lib.mutation
  local function undoable() return mutation.undo_for(S.constants.UI_PAGES.index.SEQ, "pattern", 2) == true end
  local function randomized() key(1, 1); tap(2); key(1, 0); assert_true(undoable(), "an undo is held") end
  randomized(); enc(3, 1); assert_true(not undoable(), "E3 ends it")
  randomized(); key(1, 0); tap(3); assert_true(not undoable(), "K3 (a toggle) ends it")
  randomized(); toggle_pattern_step(2, 5); assert_true(not undoable(), "toggle_pattern_step ends it")
  randomized(); clear_pattern(2); assert_true(not undoable(), "clear_pattern ends it")
  randomized(); key(1, 1); tap(3); key(1, 0); assert_true(not undoable(), "ALT+K3 (clear) ends it")
  randomized(); S.lib.sequencer.replace_pattern(2, {1}); assert_true(not undoable(), "replace_pattern ends it")
  randomized(); S.lib.sequencer.replace_pattern(5, {1}); assert_true(undoable(), "another voice's edit does not")
end)

test("undo while the pattern clock plays restores the old steps (#557)", function()
  local context, S = started_on_seq()
  S.selected_voice = 1
  S.patterns[1][3] = 9
  local old = steps_of(S, 1)
  tap(2)
  assert_true(S.pattern_playing)
  context.clock.run_for(0.3)
  key(1, 1); tap(2)
  context.clock.run_for(0.3)
  assert_true(S.pattern_sounding_step ~= nil, "a step played between the randomize and the undo")
  tap(2)
  assert_true(same_steps(steps_of(S, 1), old), "the exact old steps are back")
  key(1, 0)
  tap(2)
end)

-- 3.4 (design 8.6, Question 12): the hold opens the edit view
test("SEQ's hold of ALT+K2 opens the edit view and randomizes nothing", function()
  local context, S = started_on_seq()
  key(1, 1); key(2, 1); context.clock.run_for(0.6); redraw()
  assert_equal(hint_text(context), "K2:edit K3:clr E3:bpm", "held")
  key(2, 0); key(1, 0)
  for step = 1, 16 do assert_equal(S.patterns[1][step], 0, "nothing randomized") end
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "v1 step 1"), "the edit view shows")
end)

-- K1 let go before K2: the release still randomizes or cancels, so the
-- hint row keeps K2's release hint, alone, until K2 comes up
test("K2's release hint stays after K1 comes up first (#557)", function()
  local context = started_on_seq()
  context.screen.clear(); redraw()
  local plain = hint_text(context)
  key(1, 1); key(2, 1); key(1, 0)
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:rand", "K1 up, K2 down: the quick release's hint")
  context.clock.run_for(0.6); context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:edit", "held past the hold time: letting go opens the edit view")
  key(2, 0); context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:back K3:step E3:length", "K2 up: the edit view's plain hints")
  assert_true(plain ~= hint_text(context), "not the pattern view's")
end)

test("SEQ hints", function()
  local context, S = started_on_seq()
  assert_equal(hint_text(context), "K2:play K3:step E3:level", "stopped")
  tap(2); redraw()
  assert_equal(hint_text(context), "K2:stop K3:step E3:level", "playing")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:clr E3:bpm", "ALT")
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
  S.pattern_sounding_steps[1] = nil
  redraw()
  assert_equal(cell(context, 1, 2).level, 9, "nothing sounding: no playing column")
  tap(2)
end)

---------------------------------------------------------------------------
-- 3.4 (design 8.6, 8.7, 8.12, 8.13): the pattern view's lengths, playheads
-- and gate marks, the edit view and the step editor

-- The edit view's rows (design 8.6, as VOICE's): 7 px apart from y 24, five
-- in view, labels at x 3 (level 15 under the cursor), values right-aligned
-- at x 124
local EDIT = { first_y = 24, spacing = 7, visible = 5, field_x = 3, value_right = 124 }

-- The cursor row's label and value on the drawn screen (nil when none)
local function cursor_row(context)
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == EDIT.field_x and entry.level == 15 and entry.y >= EDIT.first_y
      and entry.y <= EDIT.first_y + (EDIT.visible - 1) * EDIT.spacing then
      for _, other in ipairs(context.screen.texts) do
        if other.y == entry.y and other.x == EDIT.value_right and other.align == "right" then
          return entry.text, other.text
        end
      end
      return entry.text, nil
    end
  end
end

local function screen_signature(context)
  local parts = {}
  for _, entry in ipairs(context.screen.texts) do
    parts[#parts + 1] = entry.x .. "," .. entry.y .. "," .. entry.level .. "," .. entry.text
  end
  return table.concat(parts, ";")
end

-- Walk the edit view's rows with E2 from the first and call visit(label,
-- value) on each; the walk ends where E2 changes nothing. Returns true
-- when visit did
local function walk_rows(context, visit)
  enc(2, -100)
  local last
  for _ = 1, 60 do
    context.screen.clear(); redraw()
    local signature = screen_signature(context)
    if signature == last then return false end
    last = signature
    if visit(cursor_row(context)) then return true end
    enc(2, 1)
  end
  return false
end

-- Every row's label, in order, as one string
local function row_labels(context)
  local labels = {}
  walk_rows(context, function(label) labels[#labels + 1] = label end)
  return table.concat(labels, " ")
end

-- Put the cursor on the nth row labeled label and return its value as drawn
local function go_to(context, label, nth)
  local seen, found = 0, nil
  local reached = walk_rows(context, function(text, value)
    if text == label then
      seen = seen + 1
      if seen == (nth or 1) then found = value; return true end
    end
  end)
  assert_true(reached, "the edit view has a row " .. label .. " (" .. (nth or 1) .. ")")
  return found
end

-- The value the cursor row shows now
local function shown(context)
  context.screen.clear(); redraw()
  return select(2, cursor_row(context))
end

-- ALT+K2 held past the hold time, then let go
local function alt_k2_hold(context)
  key(1, 1); key(2, 1)
  context.clock.run_for(local_value("S").constants.ALT_HOLD_SECONDS + 0.05)
  key(2, 0); key(1, 0)
end

local function open_edit_view(context)
  alt_k2_hold(context)
  context.screen.clear(); redraw()
end

-- The marks drawn on a pattern row's baseline besides its number and run state
local function row_marks(context, voice_idx)
  local count = 0
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == row_y(voice_idx) + 5 and entry.x ~= 0 and entry.x ~= 127 then count = count + 1 end
  end
  return count
end

test("steps past a voice's length draw as dots and each row plays its own step", function()
  local context, S = started_on_seq()
  params:set("v2_seq_length", 5)
  S.patterns[2][4] = 9; S.patterns[2][9] = 12
  redraw()
  assert_true(cell(context, 2, 5), "step 5 of a five-step voice is a cell")
  assert_equal(cell(context, 2, 4).level, 9, "a step inside the length keeps its level")
  for step = 6, 16 do
    assert_true(cell(context, 2, step) == nil, "step " .. step .. " is no cell")
    local dot = rect_at(context, cell_x(step) + 1, row_y(2) + 1, 1, 1)
    assert_true(dot, "step " .. step .. " is a 1x1 dot")
    assert_equal(dot.level, 1, "at level 1, set or not"); assert_equal(dot.filled, true)
  end
  assert_true(cell(context, 1, 16), "voice 1 keeps its sixteen cells")
  assert_screen_layout(context, "SEQ with a five-step voice")
  -- voice 1 at 1/16 and voice 3 at 1/8: after two 16ths voice 1 sounds
  -- step 3 and voice 3 step 2
  params:set("v3_seq_division", 5)
  tap(2)
  context.clock.run_for(0.25 + 1e-6)
  redraw()
  assert_equal(cell(context, 1, 3).level, 4, "voice 1's playing column is step 3 (an empty step at 4)")
  assert_equal(cell(context, 3, 2).level, 4, "voice 3's is step 2")
  assert_equal(cell(context, 1, 2).level, 1, "voice 1 has left step 2")
  assert_equal(cell(context, 3, 3).level, 1, "voice 3 has not reached step 3")
  -- voice 2 wraps at its length: four 16ths later it sounds step 2 again
  context.clock.run_for(0.5)
  redraw()
  assert_equal(S.lib.sequencer.sounding_step(2), 2)
  assert_equal(cell(context, 2, 2).level, 4, "voice 2's playing column after its wrap")
  assert_equal(cell(context, 1, 7).level, 4, "voice 1's is step 7")
  tap(2)
end)

test("ALT+K2 held opens the edit view; a quick press still randomizes the pattern", function()
  local context, S = started_on_seq()
  S.selected_voice = 2; S.cursors.seq_step = 5
  math.randomseed(7)
  key(1, 1); tap(2); key(1, 0)
  local set = 0
  for step = 1, 16 do if S.patterns[2][step] > 0 then set = set + 1 end end
  assert_true(set > 0, "a quick press randomizes voice 2's pattern")
  local randomized = steps_of(S, 2)
  open_edit_view(context)
  assert_true(h.screen_shows(context, "v2 step 5"), "the hold opens the edit view on the voice and step")
  assert_true(same_steps(steps_of(S, 2), randomized), "the hold changes no step")
  enc(2, 1)
  assert_equal(S.cursors.seq_step, 5, "E2 moves the row, not the step")
  key(1, 1); enc(2, 3); key(1, 0)
  assert_equal(S.cursors.seq_step, 8, "ALT+E2 moves the step")
  assert_equal(S.selected_voice, 2, "and keeps the voice")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "v2 step 8"))
  -- a quick press in the edit view: the undo of the randomize, then a new one
  key(1, 1); tap(2); key(1, 0)
  for step = 1, 16 do assert_equal(S.patterns[2][step], 0, "the quick press undid the randomize: step " .. step) end
  math.randomseed(9)
  key(1, 1); tap(2); key(1, 0)
  set = 0
  for step = 1, 16 do if S.patterns[2][step] > 0 then set = set + 1 end end
  assert_true(set > 0, "the next quick press randomizes again")
  -- K2: back to the pattern view, its cursor on the step edited
  tap(2)
  context.screen.clear(); redraw()
  assert_true(not h.screen_shows(context, "v2 step 8"), "K2 goes back to the pattern view")
  assert_true(cursor_rect(context, 2, 8), "whose cursor is on step 8")
  assert_true(not S.pattern_playing, "K2 in the edit view never plays")
end)

test("the edit view edits length, division and each step attribute", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)  -- a buffer voice, whose bookmarks are set
  params:set("v1_buf_pos", 0.4); params:set("v1_grain_pitch", 1.5); params:set("v1_grain_size", 0.12)
  S.cursors.seq_step = 3
  open_edit_view(context)
  assert_equal(go_to(context, "length"), "16")
  enc(3, -4); assert_equal(params:get("v1_seq_length"), 12, "E3 sets the length"); assert_equal(shown(context), "12")
  assert_equal(go_to(context, "division"), "1/16")
  enc(3, 2); assert_equal(params:get("v1_seq_division"), 5); assert_equal(shown(context), "1/8")
  assert_equal(go_to(context, "level"), "0")
  enc(3, 9); assert_equal(S.patterns[1][3], 9, "E3 sets the step's level"); assert_equal(shown(context), "9")
  assert_equal(go_to(context, "prob"), "100%", "no probability: it plays always")
  enc(3, -20); assert_equal(seq.step_attr(1, 3, "prob"), 80); assert_equal(shown(context), "80%")
  assert_equal(go_to(context, "ratchet"), "x1")
  enc(3, 1); assert_equal(seq.step_attr(1, 3, "ratchet"), 2); assert_equal(shown(context), "x2")
  assert_equal(go_to(context, "note"), "off")
  enc(3, 3); assert_equal(seq.step_attr(1, 3, "notes")[1], 3); assert_equal(shown(context), "+3")
  enc(3, -5); assert_equal(shown(context), "-2", "a note below the voice's pitch")
  enc(3, -12); assert_equal(shown(context), "-14", "down to -14")
  enc(3, -1); assert_equal(seq.step_attr(1, 3, "notes"), nil, "below -14: off"); assert_equal(shown(context), "off")
  assert_equal(go_to(context, "pos"), "off")
  enc(3, 2); assert_near(seq.step_attr(1, 3, "pos"), 0.42, 1e-9); assert_equal(shown(context), "0.42")
  assert_near(params:get("v1_buf_pos"), 0.4, 1e-9, "the lock leaves the stored position")
  assert_equal(go_to(context, "pitch"), "off")
  enc(3, 1); enc(3, -1)
  assert_near(seq.step_attr(1, 3, "pitch"), 1.5, 1e-9)
  assert_equal(shown(context), "1.50x", "a pitch lock reads as a ratio, as MAIN's pitch does")
  assert_equal(go_to(context, "size"), "off")
  enc(3, 1); enc(3, -1)
  assert_near(seq.step_attr(1, 3, "size"), 0.12, 1e-9); assert_equal(shown(context), "0.12 s")
  assert_equal(go_to(context, "bookmark"), "off")
  enc(3, 2); assert_equal(seq.step_attr(1, 3, "bookmark"), 2); assert_equal(shown(context), "2")
  for step = 1, 16 do
    if step ~= 3 then assert_equal(S.pattern_steps[1][step], nil, "only step 3 has attributes: " .. step) end
  end
  -- K3 turns the step on and off, from any row
  go_to(context, "chain")
  tap(3); assert_equal(S.patterns[1][3], 0, "K3 turns the set step off")
  tap(3); assert_equal(S.patterns[1][3], 15, "and on at 15")
  assert_screen_layout(context, "SEQ's edit view")
end)

test("a lock or note from off starts at the stored value or 0", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  params:set("v1_buf_pos", 0.3)
  open_edit_view(context)
  go_to(context, "pos"); enc(3, 1)
  assert_near(seq.step_attr(1, 1, "pos"), 0.31, 1e-9, "a turn up from off: the stored 0.30, one step up")
  seq.set_step_attr(1, 1, "pos", nil)
  enc(3, -1)
  assert_near(seq.step_attr(1, 1, "pos"), 0.29, 1e-9, "a turn down from off: one step down")
  go_to(context, "note"); enc(3, 1)
  assert_equal(seq.step_attr(1, 1, "notes")[1], 1, "a note from off starts at 0")
  seq.set_step_attr(1, 1, "notes", nil)
  enc(3, -2)
  assert_equal(seq.step_attr(1, 1, "notes")[1], -2, "either way")
  -- the step's own gate from off starts at the voice's gate length (2 steps;
  -- one detent of its exp range, 0.05-16, is 0.01 of 0.05 x 320^x)
  params:set("v1_seq_gate_length", 2)
  go_to(context, "gate", 2); enc(3, 1)
  assert_near(seq.step_attr(1, 1, "gate"), 2.11876, 1e-4, "the step's gate starts at the voice's")
  -- a lock at its range's start goes off below it
  seq.set_step_attr(1, 1, "pos", 0.01)
  go_to(context, "pos")
  enc(3, -1); assert_near(seq.step_attr(1, 1, "pos"), 0, 1e-9, "down to the range's start")
  enc(3, -1); assert_equal(seq.step_attr(1, 1, "pos"), nil, "below it: off")
  assert_equal(shown(context), "off")
  assert_near(params:get("v1_buf_pos"), 0.3, 1e-9, "the stored position never moved")
end)

test("the first note row edits notes[1] and keeps further entries; off removes only it", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {2, 5, -1})
  open_edit_view(context)
  assert_equal(go_to(context, "note"), "+2", "the row shows notes[1]")
  enc(3, 1)
  local notes = seq.step_attr(1, 1, "notes")
  assert_equal(#notes, 3, "three notes still")
  assert_equal(notes[1], 3, "E3 moves notes[1]"); assert_equal(notes[2], 5); assert_equal(notes[3], -1, "and keeps the rest")
  enc(3, -17)
  assert_equal(seq.step_attr(1, 1, "notes")[1], -14)
  enc(3, -1)
  local left = seq.step_attr(1, 1, "notes")
  assert_equal(#left, 2, "the first note removed, the others stay")
  assert_equal(left[1], 5); assert_equal(left[2], -1)
  assert_equal(shown(context), "+5", "the first row shows the next note")
  seq.set_step_attr(1, 1, "notes", {-14, 4})
  enc(3, -1)
  assert_equal(seq.step_attr(1, 1, "notes")[1], 4); assert_equal(#seq.step_attr(1, 1, "notes"), 1)
  seq.set_step_attr(1, 1, "notes", {4})
  enc(3, -30); enc(3, -1)
  assert_equal(seq.step_attr(1, 1, "notes"), nil, "the only note removed: no list")
end)

test("a chord shows one row per note and an add row", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {0, 4, 7})
  open_edit_view(context)
  local labels = row_labels(context)
  assert_true(labels:find("note note 2 note 3 add note pos", 1, true), "rows: " .. labels)
  assert_equal(go_to(context, "note"), "0")
  assert_equal(go_to(context, "note 2"), "+4")
  assert_equal(go_to(context, "note 3"), "+7")
  assert_equal(go_to(context, "add note"), nil, "the add row has no value")
  seq.set_step_attr(1, 1, "notes", nil)
  labels = row_labels(context)
  assert_true(labels:find("note pos", 1, true) and not labels:find("add note", 1, true), "no notes: note, no add: " .. labels)
  assert_equal(go_to(context, "note"), "off")
  local eight = {}
  for index = 1, 8 do eight[index] = index end
  seq.set_step_attr(1, 1, "notes", eight)
  labels = row_labels(context)
  assert_true(labels:find("note 8 pos", 1, true) and not labels:find("add note", 1, true), "eight notes, no add: " .. labels)
end)

test("a one-note step shows add note, and the cursor stays on the notes when the add row goes", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {0})
  open_edit_view(context)
  assert_true(row_labels(context):find("note add note pos", 1, true), "a one-note step has an add row")
  local function alt_step(d) key(1, 1); enc(2, d); key(1, 0); context.screen.clear(); redraw() end
  seq.set_step_attr(1, 1, "notes", {0, 4, 7})
  go_to(context, "add note")
  alt_step(1)
  assert_equal(S.cursors.seq_step, 2)
  assert_equal((cursor_row(context)), "note", "a step with no notes: the note row")
  local seven = {}
  for index = 1, 7 do seven[index] = index end
  seq.set_step_attr(1, 1, "notes", seven)
  seq.set_step_attr(1, 2, "notes", {1, 2, 3, 4, 5, 6, 7, 8})
  alt_step(-1)
  go_to(context, "add note")
  alt_step(1)
  assert_equal((cursor_row(context)), "note 8", "eight notes: the last note row")
end)

test("SEQ's layout states count a full chord as the sequencer's most notes", function()
  local _, S = started_on_seq()
  local seen = 0
  for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.SEQ].layout_states) do
    if state.name:find("edit view eight notes rows", 1, true) then seen = seen + 1 end
  end
  -- 4 section labels + 9 voice + 5 step + 8 notes + 3 locks + 5 chain rows, five to a window
  local rows = 4 + 8 + 4 + S.lib.sequencer.SEQ.max_step_notes + 3 + 5
  assert_equal(seen, math.ceil(rows / 5), "a window for every row of an eight-note step")
end)

test("turn_note ignores an index that is not a whole number in 1..n + 1", function()
  local _, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {0, 4})
  for _, index in ipairs({0, 4, 1.5, 0 / 0, -1}) do
    assert_true(not S.lib.pages_seq.turn_step(1, 1, "notes", 1, {index = index}), "index " .. tostring(index))
    assert_equal(table.concat(seq.step_attr(1, 1, "notes"), ","), "0,4")
  end
end)

test("E3 on a note row moves that note only", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {0, 4, 7})
  open_edit_view(context)
  go_to(context, "note 2")
  enc(3, 1)
  local notes = seq.step_attr(1, 1, "notes")
  assert_equal(notes[1], 0); assert_equal(notes[2], 5); assert_equal(notes[3], 7)
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:back K3:step E3:note 2", "the hint names the row")
end)

test("turning a note below -14 removes it and closes the gap", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {0, -14, 7})
  open_edit_view(context)
  go_to(context, "note 2")
  enc(3, -1)
  local notes = seq.step_attr(1, 1, "notes")
  assert_equal(#notes, 2); assert_equal(notes[1], 0); assert_equal(notes[2], 7)
  assert_equal(shown(context), "+7", "the cursor stays on the row now showing +7")
  context.screen.clear(); redraw()
  assert_equal((cursor_row(context)), "note 2")
  -- the last note removed: the cursor goes to the last note row
  seq.set_step_attr(1, 1, "notes", {0, 3, -14})
  go_to(context, "note 3")
  enc(3, -1)
  assert_equal(#seq.step_attr(1, 1, "notes"), 2)
  context.screen.clear(); redraw()
  assert_equal((cursor_row(context)), "note 2", "the last note row")
end)

test("E3 on add note appends at the last note's degree; the cursor lands on it", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {0, 4})
  open_edit_view(context)
  go_to(context, "add note")
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:back K3:step E3:add note")
  enc(3, 1)
  local notes = seq.step_attr(1, 1, "notes")
  assert_equal(#notes, 3); assert_equal(notes[3], 4, "the last note's degree")
  context.screen.clear(); redraw()
  assert_equal((cursor_row(context)), "note 3", "the cursor on the new note")
  seq.set_step_attr(1, 1, "notes", {0, 4})
  go_to(context, "add note")
  enc(3, 3)
  assert_equal(seq.step_attr(1, 1, "notes")[3], 6, "d - 1 steps from the last degree")
  seq.set_step_attr(1, 1, "notes", {0, 4})
  go_to(context, "add note")
  enc(3, -2)
  assert_equal(seq.step_attr(1, 1, "notes")[3], 2, "a turn down: d steps")
  -- the turn_step entry point
  seq.set_step_attr(1, 1, "notes", {0, 4})
  assert_true(S.lib.pages_seq.turn_step(1, 1, "notes", 1, {index = 3}))
  assert_equal(#seq.step_attr(1, 1, "notes"), 3)
  assert_true(not S.lib.pages_seq.turn_step(1, 1, "notes", 1, {index = 5}), "no gap")
  local eight = {}
  for index = 1, 8 do eight[index] = 0 end
  seq.set_step_attr(1, 1, "notes", eight)
  assert_true(not S.lib.pages_seq.turn_step(1, 1, "notes", 1, {index = 9}), "no ninth note")
end)

test("ALT+K2 held on a note row removes that note", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  seq.set_step_attr(1, 1, "notes", {4, 7, 9})
  open_edit_view(context)
  go_to(context, "note 2")
  alt_k2_hold(context)
  local notes = seq.step_attr(1, 1, "notes")
  assert_equal(#notes, 2); assert_equal(notes[1], 4); assert_equal(notes[2], 9)
  go_to(context, "note")
  alt_k2_hold(context)
  assert_equal(#seq.step_attr(1, 1, "notes"), 1)
  assert_equal(seq.step_attr(1, 1, "notes")[1], 9)
  alt_k2_hold(context)
  assert_equal(seq.step_attr(1, 1, "notes"), nil, "the only note removed")
  seq.set_step_attr(1, 1, "notes", {4, 7})
  go_to(context, "add note")
  alt_k2_hold(context)
  assert_equal(#seq.step_attr(1, 1, "notes"), 2, "the add row has nothing to reset")
end)

test("the widest chord fits: eight notes at -14 in the step editor", function()
  local context, S = started_on_seq()
  local eight = {}
  for index = 1, 8 do eight[index] = -14 end
  S.lib.sequencer.set_step_attr(7, 16, "notes", eight)
  assert_true(S.lib.pages_seq.open_step_editor(7, 16, 1))
  context.screen.clear(); redraw()
  assert_screen_layout(context, "step editor, eight notes")
  local seen = 0
  for _ = 1, 40 do
    enc(2, 1)
    context.screen.clear(); redraw()
    seen = seen + 1
    assert_screen_layout(context, "step editor, eight notes, scroll " .. seen)
    key(1, 1); context.screen.clear(); redraw()
    assert_screen_layout(context, "step editor, eight notes, scroll " .. seen .. ", ALT")
    key(1, 0)
  end
  S.lib.pages_seq.close_step_editor(1)
end)

test("the euclid row fills the voice's steps: E3 the hits, ALT+E3 the rotation", function()
  local context, S = started_on_seq()
  params:set("v1_seq_length", 8)
  S.patterns[1][12] = 6
  S.lib.sequencer.set_step_attr(1, 4, "prob", 50)
  open_edit_view(context)
  assert_equal(go_to(context, "euclid"), "-", "no fill yet")
  enc(3, 3)
  local expected = {15, 0, 0, 15, 0, 0, 15, 0}
  for step = 1, 8 do assert_equal(S.patterns[1][step], expected[step], "3 hits in 8: step " .. step) end
  assert_equal(S.patterns[1][12], 6, "a step past the length is kept")
  assert_equal(S.lib.sequencer.step_attr(1, 4, "prob"), 50, "and the attributes")
  assert_equal(shown(context), "3/8 +0")
  key(1, 1); enc(3, 1); key(1, 0)
  expected = {0, 15, 0, 0, 15, 0, 0, 15}
  for step = 1, 8 do assert_equal(S.patterns[1][step], expected[step], "rotated by 1: step " .. step) end
  assert_equal(shown(context), "3/8 +1")
  enc(3, -1)
  assert_equal(shown(context), "2/8 +1", "E3 keeps the rotation")
  enc(3, -5)
  assert_equal(shown(context), "0/8 +1", "the hits stop at 0")
  for step = 1, 8 do assert_equal(S.patterns[1][step], 0, "no hits: step " .. step) end
end)

test("ALT+K2 held in the edit view resets the row", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  open_edit_view(context)
  go_to(context, "division"); enc(3, 2)
  assert_equal(params:get("v1_seq_division"), 5)
  alt_k2_hold(context)
  assert_equal(params:get("v1_seq_division"), 3, "a voice param back to its default")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "v1 step 1"), "the edit view stays")
  seq.set_step_attr(1, 1, "pos", 0.7)
  go_to(context, "pos"); alt_k2_hold(context)
  assert_equal(seq.step_attr(1, 1, "pos"), nil, "a lock back to off")
  seq.set_step_attr(1, 1, "ratchet", 3)
  go_to(context, "ratchet"); alt_k2_hold(context)
  assert_equal(seq.step_attr(1, 1, "ratchet"), nil, "a ratchet back to one hit")
  params:set("seq_chain_bars", 9)
  go_to(context, "bars"); alt_k2_hold(context)
  assert_equal(params:get("seq_chain_bars"), 4, "a chain param back to its default")
  params:set("seq_chain", 1)
  go_to(context, "chain"); alt_k2_hold(context)
  assert_equal(params:get("seq_chain"), 0, "the chain off")
  for step = 1, 16 do assert_equal(S.patterns[1][step], 0, "a hold randomizes nothing") end
end)

test("the bookmark row shows only when the voice has a set bookmark", function()
  local context, S = started_on_seq()
  open_edit_view(context)
  local synth = row_labels(context)
  assert_true(not synth:find("bookmark", 1, true), "a synth voice has no bookmark row: " .. synth)
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  assert_equal(row_labels(context), "length division swing gate gate len gate rel euclid clear level prob ratchet "
    .. "gate note pos pitch size bookmark chain from scenes bars quantize", "every row, in order")
  S.buffers[1].seconds = 0
  assert_true(not row_labels(context):find("bookmark", 1, true), "an empty slot has none")
end)

-- Each row's hint names its label, so every row is checked with the cursor
-- on it (the layout states draw five windows of rows)
test("every edit view row lays out with the cursor on it, on voices 1 and 7, with and without bookmarks", function()
  for _, voice_idx in ipairs({ 1, 7 }) do
    for _, bookmarks in ipairs({ false, true }) do
      local context, S = started_on_seq()
      S.lib.ui_keys.select_voice_by(voice_idx - S.selected_voice)
      S.cursors.seq_step = 16
      if bookmarks then
        S.buffers[1].seconds = 8
        params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1)
      end
      open_edit_view(context)
      local rows = 0
      walk_rows(context, function(label)
        rows = rows + 1
        local where = string.format("v%d%s, row %s", voice_idx, bookmarks and " with bookmarks" or "", label)
        assert_screen_layout(context, where)
        key(1, 1); context.screen.clear(); redraw()
        assert_screen_layout(context, where .. ", ALT")
        key(1, 0); context.screen.clear(); redraw()
      end)
      assert_equal(rows, bookmarks and 22 or 21, "every row visited")
    end
  end
end)

test("the gate rows edit the voice's gate, its length and release, and a step's own length", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  redraw()
  assert_equal(row_marks(context, 1), 0, "no mark on an ungated voice's row")
  open_edit_view(context)
  assert_equal(go_to(context, "gate"), "off")
  enc(3, 1); assert_equal(params:get("v1_seq_gate"), 2, "E3 turns the gate on"); assert_equal(shown(context), "on")
  assert_equal(go_to(context, "gate len"), "0.50 st")
  enc(3, 1); assert_true(params:get("v1_seq_gate_length") > 0.5, "E3 lengthens it")
  assert_equal(go_to(context, "gate rel"), "0.10 s")
  enc(3, -1); assert_true(params:get("v1_seq_gate_release") < 0.1, "E3 shortens the release")
  assert_equal(go_to(context, "swing"), "50%")
  enc(3, 8); assert_equal(params:get("v1_seq_swing"), 58); assert_equal(shown(context), "58%")
  assert_equal(go_to(context, "gate", 2), "off", "the step's gate: the voice's length")
  seq.set_step_attr(1, 1, "gate", 2)
  assert_equal(shown(context), "2.00 st")
  alt_k2_hold(context)
  assert_equal(seq.step_attr(1, 1, "gate"), nil); assert_equal(shown(context), "off")
  tap(2)  -- back to the pattern view
  context.screen.clear(); redraw()
  assert_equal(row_marks(context, 1), 1, "the pattern view marks voice 1's gated row")
  assert_equal(row_marks(context, 2), 0, "and not voice 2's")
  params:set("v2_seq_gate", 2)
  context.screen.clear(); redraw()
  assert_equal(row_marks(context, 2), 1, "two gated voices, one under the other")
  assert_screen_layout(context, "SEQ with two gated voices")
end)

test("open_step_editor shows the editor over any page and close_step_editor returns to it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages_seq = S.lib.pages_seq
  show_page("MAIN")
  assert_equal(pages_seq.step_editor(), nil, "no editor before an open")
  assert_equal(pages_seq.open_step_editor(3, 5, 1), true)
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "v3 step 5"), "the screen shows the editor")
  assert_equal(context.screen.texts[1].text, "MAIN", "under MAIN's header")
  local editor = pages_seq.step_editor()
  assert_equal(editor.voice, 3); assert_equal(editor.step, 5); assert_equal(editor.port, 1)
  assert_equal((cursor_row(context)), "level", "it opens on the step's level")
  enc(1, 2)
  assert_equal(local_value("ui_page"), 1, "E1 does nothing")
  enc(3, 4)
  assert_equal(S.patterns[3][5], 4, "E3 sets the editor's step's level")
  local selected = S.selected_voice
  enc(2, 1); context.screen.clear(); redraw()
  assert_equal((cursor_row(context)), "prob", "E2 moves the editor's row")
  assert_equal(S.selected_voice, selected, "the selected voice stays")
  pages_seq.close_step_editor(1)
  assert_equal(pages_seq.step_editor(), nil, "closed")
  assert_equal(S.lib.ui_modal.top(), nil, "the owner is popped")
  context.screen.clear(); redraw()
  assert_true(not h.screen_shows(context, "v3 step 5"), "MAIN again")
  assert_screen_layout(context, "MAIN after the step editor")
  -- a second open from another port replaces the first, whose close then
  -- does nothing
  assert_equal(pages_seq.open_step_editor(3, 5, 1), true)
  enc(3, 1)
  assert_equal(pages_seq.open_step_editor(6, 12, 2), true)
  editor = pages_seq.step_editor()
  assert_equal(editor.voice, 6); assert_equal(editor.step, 12); assert_equal(editor.port, 2)
  pages_seq.close_step_editor(1)
  assert_true(pages_seq.step_editor() ~= nil, "the first port's close leaves the second's editor")
  pages_seq.close_step_editor(2)
  assert_equal(pages_seq.step_editor(), nil)
  assert_equal(S.lib.ui_modal.top(), nil)
  -- an editor for no step opens nothing
  assert_equal(pages_seq.open_step_editor(8, 1, 1), false, "voice 8")
  assert_equal(pages_seq.open_step_editor(1, 17, 1), false, "step 17")
  assert_equal(pages_seq.step_editor(), nil)
  for _, page in ipairs({ "VOICE", "SEQ", "BUFFER", "SETUP" }) do
    show_page(page)
    pages_seq.open_step_editor(7, 16, 1)
    context.screen.clear(); redraw()
    assert_true(h.screen_shows(context, "v7 step 16"), "the editor over " .. page)
    pages_seq.close_step_editor(1)
  end
end)

test("the step editor's keys act on its own voice and step", function()
  local context, S = started_on_seq()
  local seq = S.lib.sequencer
  local pages_seq = S.lib.pages_seq
  S.selected_voice = 1; S.cursors.seq_step = 1
  pages_seq.open_step_editor(4, 6, 1)
  tap(3)
  assert_equal(S.patterns[4][6], 15, "K3 turns the editor's step on")
  assert_equal(S.patterns[1][1], 0, "not the page's")
  key(1, 1); enc(2, 2); key(1, 0)
  assert_equal(pages_seq.step_editor().step, 8, "ALT+E2 moves the editor's step")
  assert_equal(S.cursors.seq_step, 1, "and leaves SEQ's cursor")
  context.screen.clear(); redraw()
  assert_true(h.screen_shows(context, "v4 step 8"))
  math.randomseed(4)
  key(1, 1); tap(2); key(1, 0)
  local set = 0
  for step = 1, 16 do if S.patterns[4][step] > 0 then set = set + 1 end end
  assert_true(set > 0, "a quick ALT+K2 randomizes the editor's voice")
  for step = 1, 16 do assert_equal(S.patterns[1][step], 0, "and no other voice") end
  key(1, 1); tap(2); key(1, 0)
  for step = 1, 16 do
    assert_equal(S.patterns[4][step], step == 6 and 15 or 0, "a second quick press undoes it: step " .. step)
  end
  enc(2, 1); enc(3, -10)
  assert_equal(seq.step_attr(4, 8, "prob"), 90)
  key(1, 1); key(2, 1); context.clock.run_for(0.6)
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:reset K3:clr E2:step", "held: letting go resets the row")
  key(2, 0); key(1, 0)
  assert_equal(seq.step_attr(4, 8, "prob"), nil, "the hold reset the row")
  key(1, 1); tap(3); key(1, 0)
  for step = 1, 16 do assert_equal(S.patterns[4][step], 0, "ALT+K3 clears the editor's voice") end
  tap(2)
  assert_equal(pages_seq.step_editor(), nil, "K2 closes the editor")
  context.screen.clear(); redraw()
  assert_true(not h.screen_shows(context, "v4 step 8"), "SEQ again")
  assert_true(not S.pattern_playing, "K2 in the editor never plays")
end)

test("the hint rows", function()
  local context, S = started_on_seq()
  local function hints() context.screen.clear(); redraw(); return hint_text(context) end
  assert_equal(hints(), "K2:play K3:step E3:level", "the pattern view")
  key(1, 1); assert_equal(hints(), "K2:rand K3:clr E3:bpm", "with ALT")
  key(2, 1); context.clock.run_for(0.6)
  assert_equal(hints(), "K2:edit K3:clr E3:bpm", "ALT+K2 held: letting go opens the edit view")
  key(2, 0); key(1, 0)
  assert_equal(hints(), "K2:back K3:step E3:length", "the edit view, on its first row")
  go_to(context, "gate rel"); assert_equal(hints(), "K2:back K3:step E3:gate rel")
  go_to(context, "prob"); assert_equal(hints(), "K2:back K3:step E3:prob")
  go_to(context, "clear"); assert_equal(hints(), "K2:back K3:clr", "on the clear row K3 clears")
  go_to(context, "quantize"); assert_equal(hints(), "K2:back K3:step E3:quantize")
  key(1, 1); assert_equal(hints(), "K2:rand K3:clr E2:step", "the edit view with ALT")
  key(2, 1); context.clock.run_for(0.6)
  assert_equal(hints(), "K2:reset K3:clr E2:step", "held: letting go resets the row")
  key(2, 0); key(1, 0)
  -- the euclid and clear rows have nothing to reset: held, letting go only
  -- cancels the quick press's randomize (#596)
  local function held_hints()
    key(1, 1); key(2, 1); context.clock.run_for(0.6)
    local with_alt = hints()
    key(1, 0)
    local alone = hints()
    key(2, 0)
    return with_alt, alone
  end
  for _, label in ipairs({ "euclid", "clear" }) do
    go_to(context, label)
    local pattern = steps_of(S, S.selected_voice)
    local with_alt, alone = held_hints()
    assert_equal(with_alt, "K2:cancel K3:clr E2:step", "held on " .. label .. ": letting go does nothing")
    assert_equal(alone, "K2:cancel", "K1 let go first on " .. label .. ": K2's hint alone")
    assert_true(same_steps(steps_of(S, S.selected_voice), pattern), "and letting go on " .. label .. " changed nothing")
  end
  S.lib.pages_seq.open_step_editor(2, 4, 1)
  assert_equal(hints(), "K2:back K3:step E3:level", "the step editor")
  key(1, 1); assert_equal(hints(), "K2:rand K3:clr E2:step", "the step editor with ALT")
  key(1, 0)
  local with_alt, alone = held_hints()
  assert_equal(with_alt, "K2:reset K3:clr E2:step", "held on the editor's level: letting go resets it")
  assert_equal(alone, "K2:reset")
  for _, label in ipairs({ "euclid", "clear" }) do
    go_to(context, label)
    with_alt, alone = held_hints()
    assert_equal(with_alt, "K2:cancel K3:clr E2:step", "held on the editor's " .. label .. ": letting go does nothing")
    assert_equal(alone, "K2:cancel", "K1 let go first on the editor's " .. label)
  end
  S.lib.pages_seq.close_step_editor(1)
  go_to(context, "quantize")
  assert_equal(hints(), "K2:back K3:step E3:quantize", "the edit view under it again")
end)

-- #592: over a page that does not animate (MAIN), the frame clock alone
-- (no redraw() here) turns the editor's hint at the hold time and moves its
-- strip's playhead
test("over MAIN the step editor's hint and playhead move with the frame clock alone (#592)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MAIN")
  S.lib.pages_seq.open_step_editor(1, 1, 1)
  key(1, 1); key(2, 1)
  context.clock.run_for(0.6)
  assert_equal(hint_text(context), "K2:reset K3:clr E2:step", "held past the hold time: a frame draws the reset's hint")
  key(2, 0); key(1, 0)
  -- voice 1 at 1/16 sounds step 3 from 0.25 s to 0.375 s; a frame comes every 1/15 s
  pattern_toggle()
  context.clock.run_for(0.36)
  local playing = rect_at(context, 60 + 2 * 4, 13, 3, 3)
  assert_true(playing, "the strip's step 3 is drawn")
  assert_equal(playing.level, 4, "and plays (an empty step at 4)")
  assert_equal(rect_at(context, 60, 13, 3, 3).level, 1, "step 1 no longer plays")
  pattern_toggle()
  S.lib.pages_seq.close_step_editor(1)
end)

-- The norns menu can take ALT+K2's release (K1 let go and tapped while K2
-- is down): the editor's press must not outlive it, or its owner would
-- animate (redraw at 15 fps) and its hint stay K2:reset until it closes
test("a K2 release the norns menu takes leaves the step editor neither animating nor at K2:reset", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local owner = S.lib.pages_seq.step_editor_owner
  S.lib.pages_seq.open_step_editor(2, 4, 1)
  key(1, 1); key(2, 1)
  context.clock.run_for(0.6)
  assert_true(owner.animates(), "held: the editor animates")
  _menu.set_mode(true)   -- the menu opens; K2's release goes to it
  _menu.set_mode(false)
  assert_true(not S.pattern_playing)
  assert_equal(owner.animates(), false, "after the menu, with the patterns stopped, no animation")
  key(1, 1)
  context.screen.clear(); redraw()
  assert_equal(hint_text(context), "K2:rand K3:clr E2:step", "the hint is back to the quick press's")
  key(1, 0)
  S.lib.pages_seq.close_step_editor(1)
end)

-- Ruling 71: the editor's own pattern replacements keep it open; the grids
-- read step_editor_replacing() in end_step_gestures to tell them apart
test("step_editor_replacing is true exactly while the editor's own action replaces the pattern", function()
  local context, S = started_on_seq()
  local pages_seq = S.lib.pages_seq
  local seen = {}
  local real = S.lib.grid_core.end_step_gestures
  S.lib.grid_core.end_step_gestures = function(voice_idx)
    seen[#seen + 1] = tostring(pages_seq.step_editor_replacing())
    return real(voice_idx)
  end
  local function take()
    local text = table.concat(seen, " ")
    for index = #seen, 1, -1 do seen[index] = nil end
    return text
  end
  assert_equal(pages_seq.step_editor_replacing(), false, "no editor open")
  pages_seq.open_step_editor(2, 3, 1)
  go_to(context, "euclid"); take()
  enc(3, 2); assert_equal(take(), "true", "E3 on euclid")
  key(1, 1); enc(3, 1); key(1, 0); assert_equal(take(), "true", "ALT+E3 on euclid")
  go_to(context, "clear"); take()
  tap(3); assert_equal(take(), "true", "K3 on the clear row")
  key(1, 1); tap(3); key(1, 0); assert_equal(take(), "true", "ALT+K3")
  math.randomseed(2)
  key(1, 1); tap(2); assert_equal(take(), "true", "ALT+K2's randomize")
  tap(2); key(1, 0); assert_equal(take(), "true", "and its undo")
  S.lib.sequencer.replace_pattern(2, {}); assert_equal(take(), "false", "a replacement from outside, the editor open")
  clear_pattern(5); assert_equal(take(), "false", "another voice's clear from outside")
  assert_equal(pages_seq.step_editor_replacing(), false, "false between actions")
  assert_true(pages_seq.step_editor() ~= nil, "the editor is still open")
  -- a replacement that raises still sets it back to false
  S.lib.grid_core.end_step_gestures = function() error("probe raises") end
  go_to(context, "euclid")
  local ok = pcall(enc, 3, 1)
  S.lib.grid_core.end_step_gestures = real
  assert_true(not ok, "the probe raised through the editor's E3")
  assert_equal(pages_seq.step_editor_replacing(), false, "back to false after a raise")
  pages_seq.close_step_editor(1)
  assert_equal(pages_seq.step_editor_replacing(), false, "and with no editor")
end)

end

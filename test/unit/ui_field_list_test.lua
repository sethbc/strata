-- test/unit/ui_field_list_test.lua
-- field_list (S.lib.ui_field_list): cursor moves over selectable rows, the
-- view, the ordinal and the scroll marker
-- Run alone: lua test/run.lua ui_field_list

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

local function field_list()
  load_strata()
  return local_value("S").lib.ui_field_list
end

local rows = {{label = "master", selectable = false}, {label = "density"}, {label = "filter", selectable = false}, {label = "type"}}

local function numbered(count)
  local list = {}
  for index = 1, count do list[index] = {label = "r" .. index} end
  return list
end

test("field_list moves over selectable rows only", function()
  local FL = field_list()
  assert_equal(FL.move(rows, 2, 1), 4); assert_equal(FL.move(rows, 4, 1), 4)
  assert_equal(FL.move(rows, 2, -1), 2); assert_equal(FL.move(rows, 4, -1), 2)
  assert_equal(FL.move(rows, 2, 5), 4, "a big step clamps")
end)

test("field_list counts the cursor among the selectable rows", function()
  local FL = field_list()
  assert_equal(select(1, FL.ordinal(rows, 4)), 2); assert_equal(select(2, FL.ordinal(rows, 4)), 2)
  assert_equal(select(1, FL.ordinal(rows, 2)), 1)
end)

test("field_list keeps one row above the cursor in view", function()
  local FL = field_list()
  local list = numbered(12)
  assert_equal(FL.first_visible(list, 1, 5), 1)
  assert_equal(FL.first_visible(list, 2, 5), 1)
  assert_equal(FL.first_visible(list, 6, 5), 5)
  assert_equal(FL.first_visible(list, 12, 5), 8)
  assert_equal(FL.first_visible(numbered(3), 3, 5), 1)
end)

test("field_list clamps a cursor past the end of shrunk rows", function()
  local FL = field_list()
  assert_equal(FL.clamp(rows, 9), 4); assert_equal(FL.clamp(rows, 1), 2)
  assert_equal(FL.clamp(rows, 3), 2); assert_equal(FL.clamp(rows, 4), 4)
end)

test("field_list starts a missing or invalid cursor on the first field", function()
  local FL = field_list()
  assert_equal(FL.clamp(rows, nil), 2, "nil: the first selectable row")
  assert_equal(FL.clamp(rows, "x"), 2, "not a number: the first selectable row")
  assert_equal(FL.clamp(rows, 0 / 0), 2, "NaN: the first selectable row")
  assert_equal(FL.clamp(rows, -3), 2, "before the first row")
  assert_equal(FL.move(rows, nil, 1), 4, "move starts from the first field")
  assert_equal(select(1, FL.ordinal(rows, FL.clamp(rows, nil))), 1)
end)

-- The marker's one line for first..count rows, visible at a time, on top..bottom
local function marker_line(screen, FL, first, visible, count, top, bottom)
  screen.clear()
  FL.draw_marker(first, visible, count, top, bottom)
  assert_equal(#screen.lines, 1, "one marker line")
  return screen.lines[1]
end

test("the scroll marker stays in its range and moves with a short list", function()
  local FL = field_list()
  local screen = load_strata().screen
  -- one row more than fit: the first and last views put the marker at each
  -- end, and the two positions differ
  for _, case in ipairs({ { 5, 6, 14, 56 }, { 7, 8, 12, 55 }, { 5, 6, 18, 53 }, { 6, 8, 10, 52 } }) do
    local visible, count, top, bottom = case[1], case[2], case[3], case[4]
    local where = visible .. " of " .. count .. " on " .. top .. "-" .. bottom
    local at_start = marker_line(screen, FL, 1, visible, count, top, bottom)
    local at_end = marker_line(screen, FL, count - visible + 1, visible, count, top, bottom)
    assert_equal(at_start.y1, top, where .. ": first view at the top")
    assert_equal(at_end.y2, bottom, where .. ": last view at the bottom")
    assert_true(at_end.y1 > at_start.y1, where .. ": the marker moves between the views")
  end
  -- a track shorter than the marker's minimum length never leaves it
  for first = 1, 4 do
    local line = marker_line(screen, FL, first, 5, 8, 20, 22)
    assert_true(line.y1 >= 20 and line.y2 <= 22, "first " .. first .. ": inside a 2 px track")
  end
  -- every position of every list stays between top and bottom
  for count = 6, 30 do
    for first = 1, count - 4 do
      local line = marker_line(screen, FL, first, 5, count, 14, 56)
      assert_true(line.y1 >= 14 and line.y2 <= 56 and line.y1 < line.y2,
        count .. " rows from " .. first .. ": inside 14-56")
    end
  end
end)

test("the scroll marker sits at x 127 and reaches each end", function()
  local FL = field_list()
  local context = load_strata()
  local screen = context.screen
  local function marker(first, visible, count)
    screen.clear()
    FL.draw_marker(first, visible, count, 14, 56)
    return screen.lines
  end
  local lines = marker(1, 5, 12)
  assert_equal(#lines, 1); assert_equal(lines[1].x1, 127); assert_equal(lines[1].x2, 127)
  assert_equal(lines[1].y1, 14)
  lines = marker(8, 5, 12)
  assert_equal(#lines, 1); assert_equal(lines[1].y2, 56)
  lines = marker(4, 5, 12)
  assert_true(lines[1].y1 > 14 and lines[1].y2 < 56, "the middle sits between the ends")
  assert_equal(#marker(1, 5, 5), 0, "nothing when every row fits")
end)

test("draw calls draw_row for the visible rows and marks the cursor row", function()
  local FL = field_list()
  local context = load_strata()
  context.screen.clear()
  local list = numbered(12)
  local seen = {}
  FL.draw(list, 6, {visible = 5, first_y = 16, spacing = 10},
    function(row, y, selected, value_right)
      seen[#seen + 1] = {row.label, y, selected, value_right}
    end)
  assert_equal(#seen, 5)
  assert_equal(seen[1][1], "r5"); assert_equal(seen[1][2], 16); assert_equal(seen[2][3], true)
  assert_equal(seen[2][1], "r6"); assert_equal(seen[3][3], false)
  assert_equal(seen[5][2], 56); assert_equal(seen[1][4], 124)
  assert_equal(#context.screen.lines, 1, "one scroll marker")
end)
end

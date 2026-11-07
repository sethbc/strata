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

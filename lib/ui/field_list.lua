-- lib/ui/field_list.lua
-- Stateless helpers for a page that is a list of fields with one cursor
-- (S.lib.ui_field_list). Rows are arrays of
-- {label, param_id?, selectable = true|false, section?}; a row with
-- selectable == false (a section label) takes no cursor stop. A cursor is
-- always a row index into rows, pointing at a selectable row.

return function(S)
  local M = {}

  local MARKER_X = 127
  local MARKER_MIN_LENGTH = 3
  local DEFAULT_VALUE_RIGHT = 124

  local function selectable(rows, index)
    local row = rows[index]
    return row ~= nil and row.selectable ~= false
  end

  local function first_selectable(rows)
    for index = 1, #rows do
      if selectable(rows, index) then return index end
    end
    return 1
  end

  -- Move over selectable rows by d stops; clamps at the ends, no wrap
  function M.move(rows, cursor, d)
    cursor = M.clamp(rows, cursor)
    local step = d < 0 and -1 or 1
    for _ = 1, math.abs(d) do
      local index = cursor + step
      while rows[index] ~= nil and not selectable(rows, index) do index = index + step end
      if rows[index] == nil then break end
      cursor = index
    end
    return cursor
  end

  -- The nearest selectable row at or before cursor, else the first one
  function M.clamp(rows, cursor)
    local index = math.min(math.floor(cursor), #rows)
    while index >= 1 do
      if selectable(rows, index) then return index end
      index = index - 1
    end
    return first_selectable(rows)
  end

  -- The cursor's position among the selectable rows, and how many there are
  function M.ordinal(rows, cursor)
    local position, count = 0, 0
    for index = 1, #rows do
      if selectable(rows, index) then
        count = count + 1
        if index <= cursor then position = count end
      end
    end
    return math.max(position, 1), count
  end

  -- First row in view: one row above the cursor, never past the last page
  function M.first_visible(rows, cursor, visible)
    local last_start = math.max(#rows - visible + 1, 1)
    return math.max(math.min(cursor - 1, last_start), 1)
  end

  -- A 1 px vertical line at x 127 between top and bottom: its top at top
  -- when first == 1, its bottom at bottom when the last row shows. Nothing
  -- when every row fits.
  function M.draw_marker(first, visible, count, top, bottom)
    if count <= visible then return end
    local track = bottom - top
    local length = math.max(MARKER_MIN_LENGTH, math.floor(track * visible / count + 0.5))
    local travel = track - length
    local fraction = math.min(math.max((first - 1) / (count - visible), 0), 1)
    local y = top + math.floor(travel * fraction + 0.5)
    screen.level(4)
    screen.move(MARKER_X, y)
    screen.line(MARKER_X, y + length)
    screen.stroke()
  end

  -- Call draw_row(row, y, selected) for each visible row, then draw the
  -- scroll marker. spec = {visible, first_y, spacing, value_right = 124,
  -- marker_top?, marker_bottom?}; draw_row aligns its value at
  -- spec.value_right (passed as a fourth argument).
  function M.draw(rows, cursor, spec, draw_row)
    local first = M.first_visible(rows, cursor, spec.visible)
    local value_right = spec.value_right or DEFAULT_VALUE_RIGHT
    local shown = math.min(spec.visible, #rows - first + 1)
    for offset = 0, shown - 1 do
      local index = first + offset
      draw_row(rows[index], spec.first_y + offset * spec.spacing, index == cursor, value_right)
    end
    M.draw_marker(first, spec.visible, #rows,
      spec.marker_top or (spec.first_y - 6),
      spec.marker_bottom or (spec.first_y + (spec.visible - 1) * spec.spacing + 1))
  end

  return M
end

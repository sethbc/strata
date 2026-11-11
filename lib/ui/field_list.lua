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

  -- The nearest selectable row at or before cursor, else the first one (also
  -- for a cursor that is nil, not a number or NaN: a page's cursor before
  -- its first draw)
  function M.clamp(rows, cursor)
    if type(cursor) ~= "number" or cursor ~= cursor then return first_selectable(rows) end
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

  -- First row in view: one row above the cursor, never past the last page.
  -- tail (default 0) scrolls the view that many rows further down, still
  -- never past the last page: the rows below the last selectable row are
  -- reached that way (M.move_scroll)
  function M.first_visible(rows, cursor, visible, tail)
    local last_start = math.max(#rows - visible + 1, 1)
    local first = math.max(math.min(cursor - 1, last_start), 1)
    return math.min(first + math.max(tail or 0, 0), math.max(last_start, first))
  end

  -- How far tail can go: the rows of the last page still below the view
  function M.tail_room(rows, cursor, visible)
    return M.first_visible(rows, cursor, visible, math.huge) - M.first_visible(rows, cursor, visible)
  end

  -- E2 on a list whose last rows cannot hold the cursor: move d stops, and
  -- once the cursor is on the last selectable row, scroll the view over the
  -- rows below it (and back up before the cursor moves up). Returns the new
  -- cursor and tail
  function M.move_scroll(rows, cursor, tail, d, visible)
    cursor = M.clamp(rows, cursor)
    tail = math.min(math.max(tail or 0, 0), M.tail_room(rows, cursor, visible))
    local step = d < 0 and -1 or 1
    for _ = 1, math.abs(d) do
      if step < 0 and tail > 0 then
        tail = tail - 1
      else
        local moved = M.move(rows, cursor, step)
        if moved ~= cursor then
          cursor, tail = moved, 0
        elseif step > 0 then
          tail = math.min(tail + 1, M.tail_room(rows, cursor, visible))
        end
      end
    end
    return cursor, tail
  end

  -- A 1 px vertical line at x 127 between top and bottom: its top at top
  -- when first == 1, its bottom at bottom when the last row shows. Nothing
  -- when every row fits (or the track has no length). It never leaves
  -- top..bottom and is always at least 1 px shorter than the track, so even
  -- a list one row longer than the view moves it between its two views.
  -- x: the marker's column (default MARKER_X, 127)
  function M.draw_marker(first, visible, count, top, bottom, x)
    if count <= visible then return end
    local track = bottom - top
    if track < 1 then return end
    local length = math.max(MARKER_MIN_LENGTH, math.floor(track * visible / count + 0.5))
    length = math.max(math.min(length, track - 1), 1)
    local travel = track - length
    local fraction = math.min(math.max((first - 1) / (count - visible), 0), 1)
    local y = top + math.floor(travel * fraction + 0.5)
    x = x or MARKER_X
    screen.level(4)
    screen.move(x, y)
    screen.line(x, y + length)
    screen.stroke()
  end

  -- Call draw_row(row, y, selected) for each visible row, then draw the
  -- scroll marker. spec = {visible, first_y, spacing, value_right = 124,
  -- marker_top?, marker_bottom?, tail?}; draw_row aligns its value at
  -- spec.value_right (passed as a fourth argument).
  function M.draw(rows, cursor, spec, draw_row)
    local first = M.first_visible(rows, cursor, spec.visible, spec.tail)
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

-- lib/grid/pages/positions.lua
-- Grid page 5, positions (3.8, design §10.7), two sides. Side 1: seven
-- lines of sixteen cells, a line per voice, each key a jump (a held pair a
-- loop, a slice row its slice) through S.lib.positions.grid_key. Side 2:
-- every voice's marks on its line (bookmarks 1-4, ST store, HD hold, WH
-- whole, through S.lib.positions.strip_key) and the slots' record (line 1)
-- and clear (line 2) keys on columns 9-16. Each press is held in the role
-- POSITIONS_PAGE.role (pane.press_as) and passes its pane and its still
-- (pane.pressed_as in that role), so a held key ends at every way its
-- release is lost: its own pane's page, side or half change, the 64's
-- chooser opening, the grid leaving (#865). Written in pane coordinates
-- (lib/grid/pane.lua), so it is the same on every layout

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BOOKMARKS = S.constants.NUM_BOOKMARKS
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local GRID_PAGES = S.constants.GRID_PAGES
  local CELLS = GRID_PAGES.position_cells

  -- Side 2's columns (pane coordinates): the bookmarks on 1..NUM_BOOKMARKS,
  -- then the voice's keys, and the slots from slot_column + 1 (slot n at
  -- slot_column + n); the record keys on line 1, the clear keys on line 2;
  -- role: the grid core's key role a positions press is held in
  local POSITIONS_PAGE = {
    marks = {[6] = "store", [7] = "hold", [8] = "whole"},
    slot_column = 8,
    record_line = 1,
    clear_line = 2,
    role = "positions",
  }
  M.POSITIONS_PAGE = POSITIONS_PAGE

  -- A press's still (S.lib.positions' records): the key is held in the
  -- page's role, which the core clears at every way the key ends. A press
  -- notes the role first; a release passes none. Since the role is set
  -- before S.lib.positions checks its records, a re-press of a key whose
  -- release was lost (under the 64's chooser) before the next tick makes
  -- the old record's still true again: the new press then overwrites it
  -- (the same key, cell, store or hold, the slice's same note key), which
  -- leaves nothing behind
  local function still_of(pane, x, y, z)
    if z ~= 1 then return nil end
    pane.press_as(x, y, POSITIONS_PAGE.role)
    return function() return pane.pressed_as(x, y, POSITIONS_PAGE.role) == true end
  end

  -- Side 2's mark of column x: a bookmark number, "store", "hold",
  -- "whole", or nil
  local function mark_of(x)
    if x >= 1 and x <= NUM_BOOKMARKS then return x end
    return POSITIONS_PAGE.marks[x]
  end

  -- Side 2's slot of column x, or nil
  local function slot_of(x)
    local slot = x - POSITIONS_PAGE.slot_column
    if slot >= 1 and slot <= NUM_BUFFERS then return slot end
    return nil
  end

  local function press_marks(pane, x, y, z)
    local mark = mark_of(x)
    if mark ~= nil then
      S.lib.positions.strip_key(pane.port, y, mark, z, pane.index, still_of(pane, x, y, z))
      return
    end
    local slot = slot_of(x)
    if slot == nil or z ~= 1 then return end
    if y == POSITIONS_PAGE.record_line then
      S.lib.grid_core.record_key(slot)
    elseif y == POSITIONS_PAGE.clear_line then
      S.lib.grid_core.clear_key(slot)
    end
  end

  local function draw_marks(pane, led)
    local positions = S.lib.positions
    for voice_idx = 1, NUM_VOICES do
      for n = 1, NUM_BOOKMARKS do led(n, voice_idx, positions.strip_level(voice_idx, n, pane.port)) end
      for x, mark in pairs(POSITIONS_PAGE.marks) do led(x, voice_idx, positions.strip_level(voice_idx, mark, pane.port)) end
    end
    for slot = 1, NUM_BUFFERS do
      local x = POSITIONS_PAGE.slot_column + slot
      led(x, POSITIONS_PAGE.record_line, S.lib.grid_core.record_level(slot))
      led(x, POSITIONS_PAGE.clear_line, S.lib.grid_core.CLEAR_LEVEL)
    end
  end

  M.record = {
    name = "positions",
    index = GRID_PAGES.positions,
    sides = 2,
    press = function(pane, x, y, z)
      if y < 1 or y > NUM_VOICES or x < 1 or x > CELLS then return end
      if pane.side == 2 then
        press_marks(pane, x, y, z)
      else
        S.lib.positions.grid_key(pane.port, y, x, CELLS, z, pane.index, still_of(pane, x, y, z))
      end
    end,
    redraw = function(pane, led)
      if pane.side == 2 then
        draw_marks(pane, led)
        return
      end
      for voice_idx = 1, NUM_VOICES do
        for cell = 1, CELLS do led(cell, voice_idx, S.lib.positions.grid_level(voice_idx, cell, CELLS, pane.port)) end
      end
    end,
  }
  S.register_grid_page(M.record)

  return M
end

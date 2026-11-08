-- lib/ui/cursors.lua
-- The cursors more than one page or ring set uses (S.lib.ui_cursors), kept
-- on S.cursors: voice (a row index into voice_page_rows(S.selected_voice),
-- a field_list cursor), seq_step (1..PATTERN_LENGTH) and scene (the eight
-- scene slots, then the SCENES_FIELDS params: 1..NUM_SCENES +
-- #SCENES_FIELDS). Rows can shrink under the voice cursor (a source change,
-- another selected voice), so clamp_all runs at the start of every screen
-- and arc redraw. A cursor over rows that change (voice) also keeps an
-- anchor, the row it was deliberately put on (move, place), which sync
-- finds again in the current rows.

return function(S)
  local M = {}
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local NUM_SCENES = S.constants.NUM_SCENES
  local SCENES_FIELDS = S.constants.SCENES_FIELDS

  S.cursors = {
    voice = S.lib.ui_voice_rows.first_field_row(S.selected_voice),
    seq_step = 1,
    scene = 1,
  }

  -- The cursors over rows that change: rows() gives the current rows,
  -- key(row) what the anchor remembers of a row (for voice, the param id
  -- without its "v<i>_" prefix, so the same param of another voice matches)
  local ROW_CURSORS = {
    voice = {
      rows = function() return voice_page_rows(S.selected_voice) end,
      key = function(row) return row and row.param_id and row.param_id:match("^v%d+_(.+)$") end,
    },
  }

  -- Per row cursor: {key, index}, the row it was last deliberately put on.
  -- Only move and place set it; sync only reads it, so a change of the
  -- rows and back (A -> B -> A) finds the row again
  local anchors = {}

  -- The last stop of each cursor that moves over a fixed range
  local function last_stop(name)
    if name == "seq_step" then return PATTERN_LENGTH end
    if name == "scene" then return NUM_SCENES + #SCENES_FIELDS end
    error("S.lib.ui_cursors: no cursor named " .. tostring(name), 3)
  end

  local function row_cursor(name)
    local spec = ROW_CURSORS[name]
    if spec == nil then error("S.lib.ui_cursors: no cursor over rows named " .. tostring(name), 3) end
    return spec
  end

  local function anchor_on(name, spec, rows, cursor)
    anchors[name] = {key = spec.key(rows[cursor]), index = cursor}
  end

  -- Put a row cursor on its current rows and return them with the cursor:
  -- on the anchored row when the rows have its key, otherwise clamped
  -- (field_list.clamp) from the anchored index. Idempotent: it never moves
  -- the anchor (before the first deliberate move it anchors where the
  -- cursor is), so any number of calls, from a page or the rings, give the
  -- same cursor until the rows or a deliberate move change. Code that
  -- reads the cursor (a handler, a draw, a ring) calls it first
  function M.sync(name)
    local spec = row_cursor(name)
    local field_list = S.lib.ui_field_list
    local rows = spec.rows()
    if anchors[name] == nil then
      anchor_on(name, spec, rows, field_list.clamp(rows, S.cursors[name]))
    end
    local anchor, cursor = anchors[name], nil
    for index, row in ipairs(rows) do
      if spec.key(row) == anchor.key then
        cursor = index
        break
      end
    end
    cursor = cursor or field_list.clamp(rows, anchor.index)
    S.cursors[name] = cursor
    return rows, cursor
  end

  -- Put a row cursor on row index of its current rows (clamped) and anchor
  -- it there: a deliberate move. Returns the rows and the cursor, as sync.
  -- A bare S.cursors[name] = index is taken back to the anchored row by
  -- the next sync
  function M.place(name, index)
    local spec = row_cursor(name)
    local rows = spec.rows()
    anchor_on(name, spec, rows, S.lib.ui_field_list.clamp(rows, index))
    return M.sync(name)
  end

  -- Move a cursor by d stops, clamped at its ends: a row cursor (voice)
  -- from its synced row over the selectable rows (field_list.move skips the
  -- section labels), anchored where it lands; the others over their range
  function M.move(name, d)
    if ROW_CURSORS[name] then
      local rows, cursor = M.sync(name)
      M.place(name, S.lib.ui_field_list.move(rows, cursor, d))
    else
      local last = last_stop(name)
      S.cursors[name] = util.clamp(S.cursors[name] + d, 1, last)
    end
  end

  -- Put every cursor back on a real stop: voice on a selectable row of the
  -- selected voice's current rows (field_list.clamp: the nearest one at or
  -- before it), the others within their range. It clamps the index only
  -- and never moves an anchor, so the next sync still finds the anchored row
  function M.clamp_all()
    S.cursors.voice = S.lib.ui_field_list.clamp(voice_page_rows(S.selected_voice), S.cursors.voice)
    S.cursors.seq_step = util.clamp(S.cursors.seq_step, 1, last_stop("seq_step"))
    S.cursors.scene = util.clamp(S.cursors.scene, 1, last_stop("scene"))
  end

  return M
end

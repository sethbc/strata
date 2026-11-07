-- lib/ui/cursors.lua
-- The cursors more than one page or ring set uses (S.lib.ui_cursors), kept
-- on S.cursors: voice (a row index into voice_page_rows(S.selected_voice),
-- a field_list cursor), seq_step (1..PATTERN_LENGTH) and scene (the eight
-- scene slots, then the SCENES_FIELDS params: 1..NUM_SCENES +
-- #SCENES_FIELDS). Rows can shrink under the voice cursor (a source change,
-- another selected voice), so clamp_all runs at the start of every screen
-- and arc redraw.

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

  -- The last stop of each cursor that moves over a fixed range
  local function last_stop(name)
    if name == "seq_step" then return PATTERN_LENGTH end
    if name == "scene" then return NUM_SCENES + #SCENES_FIELDS end
    error("S.lib.ui_cursors: no cursor named " .. tostring(name), 3)
  end

  -- Move a cursor by d stops, clamped at its ends: voice over the selected
  -- voice's selectable rows (field_list.move skips the section labels)
  function M.move(name, d)
    if name == "voice" then
      S.cursors.voice = S.lib.ui_field_list.move(voice_page_rows(S.selected_voice), S.cursors.voice, d)
    else
      local last = last_stop(name)
      S.cursors[name] = util.clamp(S.cursors[name] + d, 1, last)
    end
  end

  -- Put every cursor back on a real stop: voice on a selectable row of the
  -- selected voice's current rows (field_list.clamp: the nearest one at or
  -- before it), the others within their range
  function M.clamp_all()
    -- S.lib.ui_field_list comes from Task 1.5 (lib/ui/field_list.lua); until
    -- it is merged the voice cursor is left as it is, so redraws still work
    local field_list = S.lib.ui_field_list
    if field_list then
      S.cursors.voice = field_list.clamp(voice_page_rows(S.selected_voice), S.cursors.voice)
    end
    S.cursors.seq_step = util.clamp(S.cursors.seq_step, 1, last_stop("seq_step"))
    S.cursors.scene = util.clamp(S.cursors.scene, 1, last_stop("scene"))
  end

  return M
end

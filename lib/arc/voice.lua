-- lib/arc/voice.lua
-- The VOICE page's arc rings: rings 1-4 edit, in order, the rows of the
-- cursor's group of four (voice_page_group over
-- voice_page_rows(S.selected_voice), lib/ui/voice_rows.lua). Control params
-- sweep their range like every continuous ring; option and number params
-- step one whole value per ARC_VOICE.ticks_per_step ticks, carried under
-- "voice:<ring>", and binary params (registered rows) the same way, as a
-- two-value option (a step up on, a step down off; the ring dark or full).
-- Rings past the group's last row are dark and ignore turns. Sets only the arc fields (arc_delta, arc_redraw) on VOICE's
-- S.registry.pages record (lib/pages/voice.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  local ARC_VOICE = {
    ticks_per_step = 20,
    cursor_level = 15,  -- the ring of the row under the cursor
    level = 12,
  }

  -- Per ring: the param id its carried ticks were turned on, so they never
  -- step another row (another group or another voice)
  local carried_param = {}

  -- The rows and the row indices rings 1-4 edit. The rows can change under
  -- the cursor (a source change, another selected voice) before the next
  -- frame: the cursor module's sync puts it back on its anchored param (or
  -- clamps it), so a turn sees the cursor the screen will show
  local function voice_ring_rows()
    local rows, cursor = S.lib.ui_cursors.sync("voice")
    local _, row_indices = voice_page_group(rows, cursor)
    return rows, row_indices, cursor
  end

  local function arc_voice_delta(n, delta)
    local rows, row_indices = voice_ring_rows()
    local index = row_indices[n]
    if index == nil then return end  -- past the group's last row
    local row = rows[index]
    if row.kind == "control" then
      arc_sweep_param(row.param_id, delta)
      return
    end
    local ticks_key = "voice:" .. n
    if carried_param[n] ~= row.param_id then
      forget_arc_ticks(ticks_key)
      carried_param[n] = row.param_id
    end
    local steps = arc_whole_steps(ticks_key, delta, ARC_VOICE.ticks_per_step)
    if steps == 0 then return end
    if row.kind == "binary" then
      -- a two-value option: a step up turns it on, a step down off
      params:set(row.param_id, steps > 0 and 1 or 0)
    else
      delta_with_detent(row.param_id, steps)
    end
  end

  local function arc_voice_redraw(arc_port)
    local rows, row_indices, cursor = voice_ring_rows()
    for n, index in ipairs(row_indices) do
      local level = index == cursor and ARC_VOICE.cursor_level or ARC_VOICE.level
      local param_id = rows[index].param_id
      if rows[index].kind == "binary" then
        arc_ring_fill(arc_port, n, params:get(param_id), level)  -- off: dark; on: the whole ring
      else
        arc_ring_fill_param(arc_port, n, param_id, level)
      end
    end
  end

  -- VOICE's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.VOICE]
  assert(record, "lib/arc/voice.lua: no VOICE page record in S.registry.pages")
  record.arc_delta = arc_voice_delta
  record.arc_redraw = arc_voice_redraw

  return M
end

-- lib/arc/scenes.lua
-- The SCENES page's arc rings: ring 1 the scene cursor (S.cursors.scene)
-- over the same stops as E2 (the eight slots, then the SCENES_FIELDS),
-- ARC_SCENES.ticks_per_stop ticks a stop carried under "scenes:1"; ring 2
-- the transition time; rings 3-4 dark (3.4's morph will take ring 3). Sets
-- only the arc fields (arc_delta, arc_redraw) on SCENES's S.registry.pages
-- record (lib/pages/scenes.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_SCENES = S.constants.NUM_SCENES
  local SCENES_FIELDS = S.constants.SCENES_FIELDS

  local ARC_SCENES = {
    ticks_per_stop = 10,
    level = 12,
  }

  -- A cursor move disarms a pending overwrite confirmation, as E2 does
  -- (S.scenes_page, lib/pages/scenes.lua)
  local function move_cursor(steps)
    local before = S.cursors.scene
    S.lib.ui_cursors.move("scene", steps)
    local page = S.scenes_page
    if S.cursors.scene ~= before and page and page.armed_slot then
      page.armed_slot = nil
      page.armed_until = 0
    end
  end

  local function arc_scenes_delta(n, delta)
    if n == 1 then
      local steps = arc_whole_steps("scenes:1", delta, ARC_SCENES.ticks_per_stop)
      if steps ~= 0 then move_cursor(steps) end
    elseif n == 2 then
      arc_sweep_param("scene_transition_time", delta)
    end
  end

  -- Ring 1 shows the cursor's position (exactly this fraction), ring 2 its param
  local function arc_scenes_redraw(arc_port)
    local last_stop = NUM_SCENES + #SCENES_FIELDS
    arc_ring_fill(arc_port, 1, (S.cursors.scene - 1) / (last_stop - 1), ARC_SCENES.level)
    arc_ring_fill_param(arc_port, 2, "scene_transition_time", ARC_SCENES.level)
  end

  -- SCENES's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.SCENES]
  assert(record, "lib/arc/scenes.lua: no SCENES page record in S.registry.pages")
  record.arc_delta = arc_scenes_delta
  record.arc_redraw = arc_scenes_redraw

  return M
end

-- lib/arc/scenes.lua
-- The SCENES page's arc rings: ring 1 the scene cursor (S.cursors.scene)
-- over the same 20 stops as E2 (the sixteen slots, then the SCENES_FIELDS),
-- ARC_SCENES.ticks_per_stop ticks a stop carried under "scenes:1", moved
-- through S.lib.pages_scenes.move_cursor as E2 moves it; ring 2
-- the transition time; ring 3 the morph (3.4, design §9.4), ring 4 morph B,
-- ARC_SCENES.ticks_per_scene ticks a scene carried under "scenes:4". Sets
-- only the arc fields (arc_delta, arc_redraw) on SCENES's S.registry.pages
-- record (lib/pages/scenes.lua).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_SCENES = S.constants.NUM_SCENES
  local SCENES_FIELDS = S.constants.SCENES_FIELDS

  local ARC_SCENES = {
    ticks_per_stop = 10,
    ticks_per_scene = 20,
    level = 12,
  }

  local function arc_scenes_delta(n, delta)
    if n == 1 then
      local steps = arc_whole_steps("scenes:1", delta, ARC_SCENES.ticks_per_stop)
      -- the page's own move, as E2's: it disarms a pending overwrite
      if steps ~= 0 then S.lib.pages_scenes.move_cursor(S.cursors.scene + steps) end
    elseif n == 2 then
      arc_sweep_param("scene_transition_time", delta)
    elseif n == 3 then
      arc_sweep_param("morph", delta)
    elseif n == 4 then
      local steps = arc_whole_steps("scenes:4", delta, ARC_SCENES.ticks_per_scene)
      if steps ~= 0 then delta_with_detent("morph_b", steps, {source = "arc"}) end
    end
  end

  -- Ring 1 shows the cursor's position (exactly this fraction), rings 2-4
  -- their params
  local function arc_scenes_redraw(arc_port)
    local last_stop = NUM_SCENES + #SCENES_FIELDS
    arc_ring_fill_position(arc_port, 1, (S.cursors.scene - 1) / (last_stop - 1), ARC_SCENES.level)
    arc_ring_fill_param(arc_port, 2, "scene_transition_time", ARC_SCENES.level)
    arc_ring_fill_param(arc_port, 3, "morph", ARC_SCENES.level)
    arc_ring_fill_param(arc_port, 4, "morph_b", ARC_SCENES.level)
  end

  -- SCENES's record gains its rings: arc_delta and arc_redraw in
  -- lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.SCENES]
  assert(record, "lib/arc/scenes.lua: no SCENES page record in S.registry.pages")
  record.arc_delta = arc_scenes_delta
  record.arc_redraw = arc_scenes_redraw

  return M
end

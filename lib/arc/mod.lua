-- lib/arc/mod.lua
-- The MOD page's arc rings (3.4, design §10 and §10.2). In the list view
-- rings 1-4 are the shown bank's four macros (S.lib.macros.bank_macros), or,
-- with the cursor on a routing, the depths of the four routings around it
-- (R1-R4, R5-R8, ...; bipolar); with ALT, ring 1 the morph, 2 scatter's
-- depth, 3 its rate, 4 morph B in whole steps. In the target view: the
-- cursor row's min and max (0-1 in a full turn), the macro, the row. In the
-- routing view: the depth, then the source, the destination and the
-- routing in whole steps. The whole-step rings carry their ticks through
-- arc_whole_steps under "mod:<what>", and forget them when what they were
-- turned on changes: the view (each opening of one), the section, the
-- shown bank, the macro or the routing (S.lib.pages_mod.carry_context; a
-- page change forgets every carry). The rings read and move the page's
-- state only through S.lib.pages_mod. Sets only the arc fields (arc_delta,
-- arc_redraw, arc_alt_delta, arc_alt_redraw) on MOD's S.registry.pages
-- record (lib/pages/mod.lua, whose arc_button the button is).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local MATRIX_SLOTS = S.constants.MATRIX_SLOTS
  local MACRO_TARGETS = S.constants.MACRO_TARGETS

  -- ticks_per_step: the whole-step rings' (morph B a scene, a source, a
  -- destination, a routing, a target row); group: the routings a ring set
  -- shows; levels: a ring's, and a routing's that does not play
  local ARC_MOD = {
    ticks_per_step = 20,
    group = 4,
    levels = {ring = 12, dim = 4},
    alt_params = {"morph", "scatter_depth", "scatter_rate", "morph_b"},
  }

  local function mod_page() return S.lib.pages_mod end
  local function depth_id(k) return "matrix_" .. k .. "_depth" end

  -- The context each carry was turned in: a carry turned in another is
  -- forgotten before it counts
  local carried_in = {}
  local function carried_steps(carry, context, delta)
    if carried_in[carry] ~= context then
      forget_arc_ticks(carry)
      carried_in[carry] = context
    end
    return arc_whole_steps(carry, delta, ARC_MOD.ticks_per_step)
  end

  -- The first routing of the cursor's set of four
  local function group_first(k)
    return math.floor((k - 1) / ARC_MOD.group) * ARC_MOD.group + 1
  end

  -- The param list-view ring n moves: a routing's depth on a routing row,
  -- else the shown bank's n-th macro (nil past the bank)
  local function list_param(n)
    local k = mod_page().cursor_routing()
    if k then
      local routing = group_first(k) + n - 1
      if routing <= MATRIX_SLOTS then return depth_id(routing), routing end
      return nil
    end
    local macro = S.lib.macros.bank_macros(S.lib.macros.bank())[n]
    return macro and ("macro_" .. macro) or nil
  end

  local function targets_delta(n, delta)
    local page = mod_page()
    if n == 1 or n == 2 then
      local _, _, has_target = page.target_bounds()
      if has_target then page.nudge_bound(n == 1 and "min" or "max", delta / UI_PAGES.ARC_TICKS_PER_SWEEP) end
    elseif n == 3 then
      arc_sweep_param("macro_" .. page.macro(), delta)
    elseif n == 4 then
      local steps = carried_steps("mod:target_row", page.carry_context(), delta)
      if steps ~= 0 then page.move_target_row(steps) end
    end
  end

  local function routing_delta(n, delta)
    local page = mod_page()
    if n == 1 then
      arc_sweep_param(depth_id(page.routing()), delta)
    elseif n == 2 or n == 3 then
      local steps = carried_steps(n == 2 and "mod:source" or "mod:dest", page.carry_context(), delta)
      if steps ~= 0 then
        if n == 2 then page.step_source(steps) else page.step_dest(steps) end
      end
    elseif n == 4 then
      local steps = carried_steps("mod:routing", page.carry_context(false), delta)
      if steps ~= 0 then page.move_routing(steps) end
    end
  end

  local function arc_mod_delta(n, delta)
    local view = mod_page().view()
    if view == "targets" then
      targets_delta(n, delta)
    elseif view == "routing" then
      routing_delta(n, delta)
    else
      local param_id = list_param(n)
      if param_id then arc_sweep_param(param_id, delta) end
    end
  end

  -- ALT in the list view: morph, scatter depth and rate, morph B in whole
  -- steps; the views keep their rings
  local function arc_mod_alt_delta(n, delta)
    if mod_page().view() ~= "list" then return arc_mod_delta(n, delta) end
    if n == 4 then
      local steps = carried_steps("mod:morph_b", mod_page().carry_context(), delta)
      if steps ~= 0 then delta_with_detent("morph_b", steps, {source = "arc"}) end
    elseif ARC_MOD.alt_params[n] then
      arc_sweep_param(ARC_MOD.alt_params[n], delta)
    end
  end

  local function arc_mod_redraw(arc_port)
    local page = mod_page()
    local view = page.view()
    local level = ARC_MOD.levels.ring
    if view == "targets" then
      local min, max = page.target_bounds()
      arc_ring_fill(arc_port, 1, min, level)
      arc_ring_fill(arc_port, 2, max, level)
      arc_ring_fill_param(arc_port, 3, "macro_" .. page.macro(), level)
      arc_ring_fill_position(arc_port, 4, (page.target_row() - 1) / (MACRO_TARGETS - 1), level)
    elseif view == "routing" then
      arc_ring_fill_param(arc_port, 1, depth_id(page.routing()), level)
      arc_ring_fill_position(arc_port, 2, page.source_position(), level)
      arc_ring_fill_position(arc_port, 3, page.dest_position(), level)
      arc_ring_fill_position(arc_port, 4, (page.routing() - 1) / (MATRIX_SLOTS - 1), level)
    else
      for n = 1, 4 do
        local param_id, routing = list_param(n)
        if param_id then
          local ring_level = (routing and not page.routing_plays(routing)) and ARC_MOD.levels.dim or level
          arc_ring_fill_param(arc_port, n, param_id, ring_level)
        end
      end
    end
  end

  local function arc_mod_alt_redraw(arc_port)
    if mod_page().view() ~= "list" then return arc_mod_redraw(arc_port) end
    for n, param_id in ipairs(ARC_MOD.alt_params) do
      arc_ring_fill_param(arc_port, n, param_id, ARC_MOD.levels.ring)
    end
  end

  -- MOD's record gains its rings: arc_delta and arc_redraw (and the ALT
  -- pair) in lib/arc/core.lua dispatch through S.registry.pages[S.ui_page]
  local record = S.registry.pages[UI_PAGES.index.MOD]
  assert(record, "lib/arc/mod.lua: no MOD page record in S.registry.pages")
  record.arc_delta = arc_mod_delta
  record.arc_redraw = arc_mod_redraw
  record.arc_alt_delta = arc_mod_alt_delta
  record.arc_alt_redraw = arc_mod_alt_redraw

  return M
end

-- lib/morph.lua
-- Scene morph (3.4, design §5): the morph, morph_a and morph_b params
-- (the group strata_morph), the plan between the two scenes they name and
-- the clock (S.morph_clock) that applies the morph's latest position. Morph
-- writes params and never recalls: the plan is the two scenes'
-- S.lib.scenes.scene_entries paired by id, continuous values are set
-- through S.lib.scenes.apply_entries (so a registered field's own set, a
-- macro's silent one, runs as in a transition's step) and the discrete
-- entries switch at the crossing through apply_entries' only =
-- "discrete". Every apply writes inside S.lib.engine_sync.deferrable.
-- S.lib.morph holds add_params, plan_ready and MORPH (the tunables).
-- Registers the morph clock's cleanup step, a PSET hook (a PSET load sets
-- the position without applying it) and the "morph clock" invariant.

return function(S)
  local M = {}
  local NUM_SCENES = S.constants.NUM_SCENES

  -- apply_hz: applies a second at most, while the morph moves;
  -- hysteresis: the discrete entries switch to B at 0.5 + it and back to A
  -- at 0.5 - it (epsilon absorbs a position's float error);
  -- max_values_per_apply: continuous values one apply sets, round robin;
  -- send_threshold: a value that moved less than this fraction of its
  -- param's range since morph last set it is skipped
  local MORPH = {apply_hz = 10, hysteresis = 0.02, max_values_per_apply = 120, send_threshold = 1 / 1000,
    epsilon = 1e-9, param_count = 3}
  M.MORPH = MORPH

  S.morph_clock = nil

  -- plan: the plan for the scenes and revisions it was built from (nil
  -- until first asked). applied: what the morph last set, side "a" or "b"
  -- (nil: the next apply takes the side by position, as after a plan
  -- change), values by param id and the round robin's cursor. moved: a
  -- position waits for the clock; pending: the last apply left values for
  -- the next one; flashed: the plan's empty endpoint has flashed
  local state = {plan = nil, applied = {values = {}, cursor = 1}, moved = false, pending = false, flashed = false}

  local function forget_applied()
    state.applied = {side = nil, values = {}, cursor = 1}
  end

  -- An entry's identity in both scenes' lists: a param by id, a block by
  -- key, a voice state (active, lock, pattern) by key and voice
  local function entry_key(entry)
    if entry.kind == "block" then return "block " .. entry.key end
    if entry.id then return "param " .. entry.id end
    return entry.key .. " " .. tostring(entry.voice)
  end

  local function same_value(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do
      if not same_value(value, b[key]) then return false end
    end
    for key in pairs(b) do
      if a[key] == nil then return false end
    end
    return true
  end

  -- The slot of an endpoint that holds no valid scene, else nil
  local function empty_endpoint(a, b)
    for _, slot in ipairs({a, b}) do
      local scene = S.scenes[slot]
      if not (scene and scene.populated and validate_scene(scene)) then return slot end
    end
    return nil
  end

  -- The ramps through 0 (design §10.2): every block with through_zero,
  -- asked A's value to B's and B's back to A's. The ids it names ramp; the
  -- switches run at the crossing toward their side
  local function block_ramps(data_a, data_b)
    local ids, switches = {}, {a = {}, b = {}}
    for _, record in ipairs(S.registry.scene_blocks or {}) do
      if record.through_zero then
        for side, ramps in pairs({b = record.through_zero(data_a[record.key], data_b[record.key]),
            a = record.through_zero(data_b[record.key], data_a[record.key])}) do
          for _, ramp in ipairs(ramps or {}) do
            ids[ramp.id] = true
            if ramp.switch then table.insert(switches[side], ramp.switch) end
          end
        end
      end
    end
    return ids, switches
  end

  -- A continuous pair of the plan: its param's id and voice, its value in
  -- A and B, its rounding step (a number param's whole numbers) and the
  -- move under which it is skipped
  local function plan_item(entry_a, entry_b)
    local low, high = param_range(entry_a.id)
    return {id = entry_a.id, voice = entry_a.voice, a = entry_a.value, b = entry_b.value,
      step = params:lookup_param(entry_a.id).t == params.tNUMBER and 1 or nil,
      threshold = (high - low) * MORPH.send_threshold}
  end

  -- The plan between slots a and b: continuous pairs that differ (and the
  -- ramps' ids), each side's discrete entries that differ, in recall order,
  -- and the switches. Entries equal in A and B, or in one scene only, are
  -- left out. ready is false while an endpoint is empty or invalid
  local function build_plan(a, b)
    local plan = {a = a, b = b, revision_a = S.lib.scenes.revision(a), revision_b = S.lib.scenes.revision(b)}
    plan.empty = empty_endpoint(a, b)
    plan.ready = plan.empty == nil
    if not plan.ready then return plan end
    local data_a, data_b = S.scenes[a].data, S.scenes[b].data
    local lists = {a = S.lib.scenes.scene_entries(data_a), b = S.lib.scenes.scene_entries(data_b)}
    local by_key = {a = {}, b = {}}
    for side, list in pairs(lists) do
      for _, entry in ipairs(list) do by_key[side][entry_key(entry)] = entry end
    end
    local ramp_ids
    ramp_ids, plan.switches = block_ramps(data_a, data_b)
    plan.continuous, plan.ramps, plan.discrete = {}, {}, {a = {}, b = {}}
    for _, entry_a in ipairs(lists.a) do
      local entry_b = by_key.b[entry_key(entry_a)]
      if entry_b and entry_b.kind == entry_a.kind and entry_a.kind == "continuous" then
        if ramp_ids[entry_a.id] then
          table.insert(plan.ramps, plan_item(entry_a, entry_b))
        elseif entry_a.value ~= entry_b.value then
          table.insert(plan.continuous, plan_item(entry_a, entry_b))
        end
      end
    end
    for side, other in pairs({a = "b", b = "a"}) do
      for _, entry in ipairs(lists[side]) do
        local counterpart = by_key[other][entry_key(entry)]
        if entry.kind ~= "continuous" and counterpart and counterpart.kind == entry.kind
            and not same_value(entry.value, counterpart.value) then
          table.insert(plan.discrete[side], entry)
        end
      end
    end
    return plan
  end

  -- The plan for the scenes morph_a and morph_b name now, rebuilt when
  -- either param or either slot's revision changed. A new plan forgets
  -- what was applied (its first apply takes the side by position) and may
  -- flash its empty endpoint again
  local function current_plan()
    local a, b = params:get("morph_a"), params:get("morph_b")
    local plan = state.plan
    if not (plan and plan.a == a and plan.b == b and plan.revision_a == S.lib.scenes.revision(a)
        and plan.revision_b == S.lib.scenes.revision(b)) then
      state.plan = build_plan(a, b)
      state.flashed = false
      forget_applied()
    end
    return state.plan
  end

  -- Both endpoints hold valid scenes
  function M.plan_ready()
    return current_plan().ready
  end

  -- The side the discrete entries take at position: by position when none
  -- was applied (A below 0.5, B from it), else across the hysteresis.
  -- Returns the side and whether this is a crossing
  local function side_at(position)
    local side = state.applied.side
    if side == nil then return position < 0.5 and "a" or "b", false end
    if side == "a" and position >= 0.5 + MORPH.hysteresis - MORPH.epsilon then return "b", true end
    if side == "b" and position <= 0.5 - MORPH.hysteresis + MORPH.epsilon then return "a", true end
    return side, false
  end

  local function rounded(item, value)
    if item.step then return util.round(value, item.step) end
    return value
  end

  -- A + position x (B - A), as a transition's step (util.linlin); a ramp
  -- A x (1 - 2 position) on A's side and B x (2 position - 1) on B's, 0
  -- until its side has switched
  local function blend_value(item, position)
    return rounded(item, util.linlin(0, 1, item.a, item.b, position))
  end

  local function ramp_value(item, side, position)
    if side == "a" then return rounded(item, item.a * math.max(0, 1 - 2 * position)) end
    return rounded(item, item.b * math.max(0, 2 * position - 1))
  end

  -- Whether a value is due: never set by this plan, or moved by at least
  -- its threshold (and at all) since morph set it
  local function due(item, value)
    local last = state.applied.values[item.id]
    if last == nil then return true end
    local moved = math.abs(value - last)
    return moved > 0 and moved >= item.threshold
  end

  -- The continuous writes of one apply, at most max_values_per_apply: the
  -- ramps first (their switch and their depth go together), then the
  -- plan's values round robin from the cursor. Returns the entries and
  -- whether values are left for the next apply
  local function continuous_writes(plan, side, position, entries)
    local more = false
    local function add(item, value)
      if #entries >= MORPH.max_values_per_apply then more = true; return false end
      table.insert(entries, {kind = "continuous", id = item.id, value = value, voice = item.voice})
      state.applied.values[item.id] = value
      return true
    end
    for _, item in ipairs(plan.ramps) do
      local value = ramp_value(item, side, position)
      if due(item, value) then add(item, value) end
    end
    local list, cursor = plan.continuous, state.applied.cursor
    for _ = 1, #list do
      local item = list[cursor]
      local value = blend_value(item, position)
      if due(item, value) and not add(item, value) then break end
      cursor = cursor % #list + 1
    end
    state.applied.cursor = cursor
    return entries, more
  end

  -- Write the plan at position: at a crossing the ramps go to 0, then the
  -- switches run; on a new side its discrete entries switch (recall order,
  -- apply_entries); then the continuous values. Returns whether values
  -- are left
  local function write_position(plan, position)
    local side, crossed = side_at(position)
    if side ~= state.applied.side then
      if crossed then
        local zeros = {}
        for _, item in ipairs(plan.ramps) do
          if state.applied.values[item.id] ~= 0 then
            table.insert(zeros, {kind = "continuous", id = item.id, value = 0, voice = item.voice})
            state.applied.values[item.id] = 0
          end
        end
        if #zeros > 0 then S.lib.scenes.apply_entries(zeros, {only = "continuous"}) end
        for _, switch in ipairs(plan.switches[side]) do switch() end
      end
      state.applied.side = side
      if #plan.discrete[side] > 0 then S.lib.scenes.apply_entries(plan.discrete[side], {only = "discrete"}) end
    end
    local entries, more = continuous_writes(plan, side, position, {})
    if #entries > 0 then S.lib.scenes.apply_entries(entries, {only = "continuous"}) end
    return more
  end

  -- Something else set the state since morph's last apply: a recall or a
  -- transition (morph leaves no scene current)
  local function taken_over()
    return S.current_scene ~= 0 or S.scene_transition_active
  end

  -- One apply of the morph's position. An empty or invalid endpoint
  -- flashes once per plan and changes nothing. Otherwise it cancels a
  -- running transition, writes inside deferrable, leaves no scene current
  -- and redraws. After a recall the apply starts again from the recalled
  -- state, as after a plan change. Returns whether values are left
  local function apply_position()
    local plan = current_plan()
    if not plan.ready then
      if not state.flashed then
        state.flashed = true
        header_flash("S" .. plan.empty .. " empty")
      end
      return false
    end
    if taken_over() then forget_applied() end
    cancel_scene_transition()
    local position, more = params:get("morph"), false
    S.lib.engine_sync.deferrable(function() more = write_position(plan, position) end)
    S.current_scene = 0
    request_redraw()
    grid_redraw()
    return more
  end

  local function stop_clock()
    if S.morph_clock then
      clock.cancel(S.morph_clock)
      S.morph_clock = nil
    end
    state.moved, state.pending = false, false
  end

  -- The clock runs while a move waits or values are left: its first apply
  -- on the next tick (a PSET load's hook runs before it), then one each
  -- 1 / apply_hz while the morph moves, one more at rest, and more while
  -- values are left, unless a recall took over. An error in an apply ends
  -- the clock (it forgets its own id first) and is raised again
  local function start_clock()
    if S.morph_clock then return end
    S.morph_clock = clock.run(function()
      clock.sleep(0)
      while state.moved or (state.pending and not taken_over()) do
        state.moved = false
        local applied, result = xpcall(apply_position, with_traceback)
        if not applied then
          S.morph_clock = nil
          state.pending = false
          forget_applied()
          error(result, 0)
        end
        state.pending = result
        clock.sleep(1 / MORPH.apply_hz)
      end
      S.morph_clock = nil
      state.pending = false
    end)
  end

  -- The morph's own params, in the group strata_morph (the menu record
  -- "morph" of lib/params_setup.lua adds them). None is a scene field, an
  -- LFO destination or a macro target
  local function percent(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end

  function M.add_params()
    params:add_group("strata_morph", "morph", MORPH.param_count)
    params:add{type = "control", id = "morph", name = "morph",
      controlspec = controlspec.new(0, 1, "lin", 0, 0, ""), formatter = percent,
      action = function()
        state.moved = true
        start_clock()
      end}
    params:add{type = "number", id = "morph_a", name = "morph A", min = 1, max = NUM_SCENES, default = 1}
    params:add{type = "number", id = "morph_b", name = "morph B", min = 1, max = NUM_SCENES, default = 2}
  end

  -- A PSET load sets the morph (its action starts the clock) with the
  -- PSET's own values: nothing applies, and the next move starts again
  -- from the loaded state
  S.register_pset_hook({name = "morph", read = function()
    stop_clock()
    forget_applied()
  end})

  S.register_cleanup(S.constants.CLEANUP_ORDER.morph_clock, function()
    stop_clock()
  end)

  -- A move or values left always have a clock to apply them, and the
  -- clock is a live coroutine
  S.register_invariant("morph clock", function()
    if (state.moved or state.pending) and S.morph_clock == nil then
      return "a morph apply waits (moved " .. tostring(state.moved) .. ", pending " .. tostring(state.pending)
        .. ") but no clock runs"
    end
    local thread = S.morph_clock and clock.threads and clock.threads[S.morph_clock]
    if S.morph_clock and type(thread) == "thread" and coroutine.status(thread) == "dead" then
      return "the morph clock " .. tostring(S.morph_clock) .. " has ended"
    end
  end)

  return M
end

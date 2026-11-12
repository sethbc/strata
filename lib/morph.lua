-- lib/morph.lua
-- Scene morph (3.4, design §5, the XY morph of §5.5): the params morph and
-- morph_y (the position, x and y), morph_a to morph_d (the four corners'
-- scenes: A at (0, 0), B at (1, 0), C at (0, 1), D at (1, 1)), in the group
-- strata_morph, the plan over the four scenes they name and the clock
-- (S.morph_clock) that applies the latest position. Morph writes params and
-- never recalls: the plan is the scenes' S.lib.scenes.scene_entries paired
-- by id, each continuous value (the corners' values weighted by the
-- position) is set through S.lib.scenes.set_value, the setter a
-- transition's step uses (a registered field's own set, a macro's silent
-- one; a quantized freq snaps), and the discrete entries switch to the
-- current corner's through S.lib.scenes.apply_entries' only = "discrete".
-- At y = 0 it is the morph between A and B, value for value. Every apply
-- writes inside S.lib.engine_sync.deferrable.
-- S.lib.morph holds add_params, plan_ready, weights, corner and MORPH (the
-- tunables). Registers the morph clock's cleanup step, a PSET hook (a PSET
-- load sets the position without applying it) and the "morph clock"
-- invariant.

return function(S)
  local M = {}
  local NUM_SCENES = S.constants.NUM_SCENES

  -- apply_hz: applies a second at most, while the morph moves;
  -- hysteresis: the discrete entries switch to another corner when its
  -- weight leads the current corner's by twice it (at y = 0: to B at
  -- 0.5 + it, back to A at 0.5 - it; epsilon absorbs a position's float
  -- error); max_values_per_apply: continuous values one apply sets, round
  -- robin; send_threshold: while the morph moves, a value that moved less
  -- than this fraction of its param's range since morph last set it is
  -- skipped (the applies at rest set every value that moved at all);
  -- corners: in the order ties go to; min_corners: the valid corners the
  -- morph needs
  local MORPH = {apply_hz = 10, hysteresis = 0.02, max_values_per_apply = 120, send_threshold = 1 / 1000,
    epsilon = 1e-9, param_count = 6, corners = {"a", "b", "c", "d"}, min_corners = 2}
  M.MORPH = MORPH

  S.morph_clock = nil

  -- plan: the plan for the scenes and revisions it was built from (nil
  -- until first asked). applied: what the morph last set, corner "a" to
  -- "d" (nil: the next apply takes the corner by weight, as after a plan
  -- change), values by param id and the round robin's cursor. moved: a
  -- position waits for the clock; move_held, move_scene and
  -- move_takeovers: whether morph held the state at the latest move, the
  -- current scene then and the scenes' takeover count (a recall or fade
  -- after the move wins over it); pending: the last apply left values for
  -- the next one; flashed: the plan's empty corner has flashed
  local state = {plan = nil, applied = {values = {}, cursor = 1}, moved = false, move_held = false, move_scene = 0,
    move_takeovers = 0, pending = false, flashed = false}

  local function forget_applied()
    state.applied = {corner = nil, values = {}, cursor = 1}
  end

  -- An entry's identity in every scene's list: a param by id, a block by
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

  -- Whether a slot holds a valid scene
  local function valid_slot(slot)
    local scene = S.scenes[slot]
    return scene ~= nil and scene.populated and validate_scene(scene)
  end

  -- The ramps through 0 (design §10.2): every block with through_zero,
  -- asked from each valid corner's value to each other's. The ids it names
  -- ramp; switches[from][to] run at the crossing from one corner to the
  -- other
  local function block_ramps(corners, data)
    local ids, switches = {}, {}
    for _, from in ipairs(corners) do
      switches[from] = {}
      for _, to in ipairs(corners) do switches[from][to] = {} end
    end
    for _, record in ipairs(S.registry.scene_blocks or {}) do
      if record.through_zero then
        for _, from in ipairs(corners) do
          for _, to in ipairs(corners) do
            if from ~= to then
              for _, ramp in ipairs(record.through_zero(data[from][record.key], data[to][record.key]) or {}) do
                ids[ramp.id] = true
                if ramp.switch then table.insert(switches[from][to], ramp.switch) end
              end
            end
          end
        end
      end
    end
    return ids, switches
  end

  -- A continuous entry of the plan: its param's id and voice, its value in
  -- each valid corner, its rounding step (a number param's whole numbers)
  -- and the move under which it is skipped
  local function plan_item(entry, values)
    local low, high = param_range(entry.id)
    return {id = entry.id, voice = entry.voice, values = values,
      step = params:lookup_param(entry.id).t == params.tNUMBER and 1 or nil,
      threshold = (high - low) * MORPH.send_threshold}
  end

  -- The round robin's units: one item each, but a voice's loop pair
  -- (lib/loops.lua) is one unit, written whole whenever either value is
  -- due, start before length. A recall sets the length first while the
  -- length's filter stands down (S.scene_recall_in_progress); morph's sets
  -- are a transition step's, with the filter on, so the start goes first
  -- (its action cuts a length the new start leaves no room for) and the
  -- length, which a blend of fitting pairs always fits, after it
  local function plan_units(items)
    local LOOP = S.lib.loops.LOOP
    local units, pairs_by_voice = {}, {}
    for _, item in ipairs(items) do
      local prefix = item.voice and ("v" .. item.voice .. "_")
      local key = prefix and (item.id == prefix .. LOOP.start_key and "start"
        or item.id == prefix .. LOOP.length_key and "length")
      if key then
        local pair = pairs_by_voice[item.voice]
        if not pair then
          pair = {members = {}}
          pairs_by_voice[item.voice] = pair
          table.insert(units, pair)
        end
        pair[key] = item
      else
        table.insert(units, {members = {item}})
      end
    end
    for _, pair in pairs(pairs_by_voice) do
      if pair.start then table.insert(pair.members, pair.start) end
      if pair.length then table.insert(pair.members, pair.length) end
      pair.start, pair.length = nil, nil
    end
    return units
  end

  -- Each valid corner's entry under every key of an entry, or nil when one
  -- lacks it or holds it as another kind
  local function counterparts_of(entry, corners, by_key)
    local found = {}
    for _, corner in ipairs(corners) do
      local counterpart = by_key[corner][entry_key(entry)]
      if not (counterpart and counterpart.kind == entry.kind) then return nil end
      found[corner] = counterpart
    end
    return found
  end

  -- The plan over the four slots (by corner): the valid corners, in
  -- MORPH.corners' order; the continuous entries that differ between them
  -- (and the ramps' ids, kept whether or not they differ), as round robin
  -- units in the first valid corner's entry order; each corner's discrete
  -- entries that differ from another's, in its recall order (first, for an
  -- apply with no corner applied), and from each other corner's
  -- (between[from][to], for a crossing); the switches. An entry equal in
  -- every valid corner, or missing from one, is left out. ready is false
  -- with fewer than MORPH.min_corners valid corners; empty is then the
  -- first empty or invalid corner's slot
  local function build_plan(slots)
    local plan = {slots = slots, revisions = {}, valid = {}, corners = {}}
    for _, corner in ipairs(MORPH.corners) do
      plan.revisions[corner] = S.lib.scenes.revision(slots[corner])
      if valid_slot(slots[corner]) then
        plan.valid[corner] = true
        table.insert(plan.corners, corner)
      elseif plan.empty == nil then
        plan.empty = slots[corner]
      end
    end
    plan.ready = #plan.corners >= MORPH.min_corners
    if not plan.ready then return plan end
    local data, lists, by_key = {}, {}, {}
    for _, corner in ipairs(plan.corners) do
      data[corner] = S.scenes[slots[corner]].data
      lists[corner] = S.lib.scenes.scene_entries(data[corner])
      by_key[corner] = {}
      for _, entry in ipairs(lists[corner]) do by_key[corner][entry_key(entry)] = entry end
    end
    local ramp_ids
    ramp_ids, plan.switches = block_ramps(plan.corners, data)
    plan.reference = plan.corners[1]
    local items = {}
    plan.ramps = {}
    for _, entry in ipairs(lists[plan.reference]) do
      local counterparts = entry.kind == "continuous" and counterparts_of(entry, plan.corners, by_key)
      if counterparts then
        local values, differs = {}, false
        for corner, counterpart in pairs(counterparts) do
          values[corner] = counterpart.value
          differs = differs or counterpart.value ~= entry.value
        end
        if ramp_ids[entry.id] then
          table.insert(plan.ramps, plan_item(entry, values))
        elseif differs then
          table.insert(items, plan_item(entry, values))
        end
      end
    end
    plan.continuous = plan_units(items)
    plan.first, plan.between = {}, {}
    for _, from in ipairs(plan.corners) do plan.between[from] = {} end
    for _, to in ipairs(plan.corners) do
      plan.first[to] = {}
      for _, from in ipairs(plan.corners) do plan.between[from][to] = {} end
      for _, entry in ipairs(lists[to]) do
        local counterparts = entry.kind ~= "continuous" and counterparts_of(entry, plan.corners, by_key)
        if counterparts then
          local differs = false
          for _, from in ipairs(plan.corners) do
            if from ~= to and not same_value(entry.value, counterparts[from].value) then
              differs = true
              table.insert(plan.between[from][to], entry)
            end
          end
          if differs then table.insert(plan.first[to], entry) end
        end
      end
    end
    return plan
  end

  -- The plan for the scenes morph_a to morph_d name now, rebuilt when a
  -- corner's param or its slot's revision changed. A new plan forgets what
  -- was applied (its first apply takes the corner by weight) and may flash
  -- its empty corner again
  local function plan_is_current(plan)
    if plan == nil then return false end
    for _, corner in ipairs(MORPH.corners) do
      local slot = params:get("morph_" .. corner)
      if plan.slots[corner] ~= slot or plan.revisions[corner] ~= S.lib.scenes.revision(slot) then return false end
    end
    return true
  end

  local function current_plan()
    if not plan_is_current(state.plan) then
      local slots = {}
      for _, corner in ipairs(MORPH.corners) do slots[corner] = params:get("morph_" .. corner) end
      state.plan = build_plan(slots)
      state.flashed = false
      forget_applied()
    end
    return state.plan
  end

  -- At least two corners hold valid scenes
  function M.plan_ready()
    return current_plan().ready
  end

  -- The corners' weights at the position (x = morph, y = morph_y): A
  -- (1 - x)(1 - y), B x(1 - y), C (1 - x)y, D xy, an empty or invalid
  -- corner's shared among the valid ones in proportion (equally where they
  -- all weigh 0), so they sum to 1; every one 0 with no valid corner
  local function weights_of(plan)
    local x, y = params:get("morph"), params:get("morph_y")
    local raw = {a = (1 - x) * (1 - y), b = x * (1 - y), c = (1 - x) * y, d = x * y}
    local weights, total = {}, 0
    for _, corner in ipairs(plan.corners) do total = total + raw[corner] end
    for _, corner in ipairs(MORPH.corners) do
      if not plan.valid[corner] then
        weights[corner] = 0
      elseif total > 0 then
        weights[corner] = raw[corner] / total
      else
        weights[corner] = 1 / #plan.corners
      end
    end
    return weights
  end

  -- The weights at the position now, a, b, c, d
  function M.weights()
    local weights = weights_of(current_plan())
    return weights.a, weights.b, weights.c, weights.d
  end

  -- The corner the discrete entries take at these weights, and whether it
  -- is a crossing. With none applied: the largest weight, a tie going to
  -- the later corner (at y = 0, A below 0.5 and B from it). Else another
  -- corner once its weight leads the current one's by twice the
  -- hysteresis (the largest, a tie going to the earlier: a, b, c, d)
  local function corner_at(plan, weights)
    local current, best = state.applied.corner, nil
    if current == nil then
      for index = #plan.corners, 1, -1 do
        local corner = plan.corners[index]
        if best == nil or weights[corner] > weights[best] + MORPH.epsilon then best = corner end
      end
      return best, false
    end
    for _, corner in ipairs(plan.corners) do
      if corner ~= current and (best == nil or weights[corner] > weights[best] + MORPH.epsilon) then best = corner end
    end
    if best and weights[best] - weights[current] >= 2 * MORPH.hysteresis - MORPH.epsilon then return best, true end
    return current, false
  end

  -- The current discrete corner, "a" to "d": the one the morph applied, or
  -- the next apply takes at the position now ("a" with no valid corner)
  function M.corner()
    local plan = current_plan()
    return corner_at(plan, weights_of(plan)) or state.applied.corner or MORPH.corners[1]
  end

  local function rounded(item, value)
    if item.step then return util.round(value, item.step) end
    return value
  end

  -- The weighted sum of the corners' values, as the first valid corner's
  -- value plus each other's weighted difference from it (at y = 0, A +
  -- x (B - A), a transition step's arithmetic); a corner of weight 1 gives
  -- its own value exactly
  local function blend_value(plan, item, weights)
    local base = item.values[plan.reference]
    local value = base
    for _, corner in ipairs(plan.corners) do
      local weight = weights[corner]
      if weight == 1 then return rounded(item, item.values[corner]) end
      if corner ~= plan.reference then value = value + weight * (item.values[corner] - base) end
    end
    return rounded(item, value)
  end

  -- A ramp through 0: the current corner's value times its lead over the
  -- largest other weight (at y = 0, A x (1 - 2x) on A's side and
  -- B x (2x - 1) on B's), 0 where two corners weigh the same
  local function ramp_value(plan, item, corner, weights)
    local others = 0
    for _, other in ipairs(plan.corners) do
      if other ~= corner and weights[other] > others then others = weights[other] end
    end
    return rounded(item, item.values[corner] * math.max(0, weights[corner] - others))
  end

  -- Whether a value is due: never set by this plan, or moved since morph
  -- set it, by at least its threshold while the morph moves (exact false)
  -- and by anything at rest (exact true), so a morph at rest lands every
  -- value on its blend (at a corner, the scene's own)
  local function due(item, value, exact)
    local last = state.applied.values[item.id]
    if last == nil then return true end
    local moved = math.abs(value - last)
    return moved > 0 and (exact or moved >= item.threshold)
  end

  -- The continuous writes of one apply, {item, value} in order, at most
  -- max_values_per_apply: the ramps first (their switch and their depth go
  -- together), then the plan's units round robin from the cursor, a unit
  -- whole or not at all. Returns the writes and whether values are left
  -- for the next apply
  local function continuous_writes(plan, corner, weights, exact)
    local writes, more = {}, false
    local function add(item, value)
      table.insert(writes, {item = item, value = value})
      state.applied.values[item.id] = value
    end
    for _, item in ipairs(plan.ramps) do
      local value = ramp_value(plan, item, corner, weights)
      if due(item, value, exact) then
        if #writes >= MORPH.max_values_per_apply then more = true else add(item, value) end
      end
    end
    local units, cursor = plan.continuous, state.applied.cursor
    for _ = 1, #units do
      local unit, values, unit_due = units[cursor], {}, false
      for index, item in ipairs(unit.members) do
        values[index] = blend_value(plan, item, weights)
        unit_due = unit_due or due(item, values[index], exact)
      end
      if unit_due then
        if #writes + #unit.members > MORPH.max_values_per_apply then more = true; break end
        for index, item in ipairs(unit.members) do add(item, values[index]) end
      end
      cursor = cursor % #units + 1
    end
    state.applied.cursor = cursor
    return writes, more
  end

  -- Whether, at rest, a value of the current plan is off its exact blend
  -- (an apply that skipped it under the threshold while the morph moved).
  -- A plan rebuilt since the last apply, or none applied, waits for a move
  local function rest_due()
    local plan = state.plan
    local corner = state.applied.corner
    if not (corner and plan and plan.ready and plan_is_current(plan)) then return false end
    local weights = weights_of(plan)
    for _, item in ipairs(plan.ramps) do
      if due(item, ramp_value(plan, item, corner, weights), true) then return true end
    end
    for _, unit in ipairs(plan.continuous) do
      for _, item in ipairs(unit.members) do
        if due(item, blend_value(plan, item, weights), true) then return true end
      end
    end
    return false
  end

  -- Each value as a transition's step sets it (S.lib.scenes.set_value,
  -- no recall flag: a quantized freq snaps)
  local function set_values(writes)
    for _, write in ipairs(writes) do S.lib.scenes.set_value(write.item.id, write.value) end
  end

  -- Write the plan at these weights: at a crossing the ramps go to 0,
  -- then the switches from the old corner to the new run; on a new corner
  -- its discrete entries switch (recall order, apply_entries: those that
  -- differ from the old corner's, or with none applied, from any other's);
  -- then the continuous values. Returns whether values are left
  local function write_position(plan, weights, exact)
    local corner, crossed = corner_at(plan, weights)
    local from = state.applied.corner
    if corner ~= from then
      if crossed then
        local zeros = {}
        for _, item in ipairs(plan.ramps) do
          if state.applied.values[item.id] ~= 0 then
            table.insert(zeros, {item = item, value = 0})
            state.applied.values[item.id] = 0
          end
        end
        set_values(zeros)
        for _, switch in ipairs(plan.switches[from][corner]) do switch() end
      end
      state.applied.corner = corner
      local entries = crossed and plan.between[from][corner] or plan.first[corner]
      if #entries > 0 then S.lib.scenes.apply_entries(entries, {only = "discrete"}) end
    end
    local writes, more = continuous_writes(plan, corner, weights, exact)
    set_values(writes)
    return more
  end

  -- Something else set the state since morph's last apply: a recall or a
  -- transition (morph leaves no scene current)
  local function taken_over()
    return S.current_scene ~= 0 or S.scene_transition_active
  end

  -- A recall or a fade came after the latest move: something took over
  -- that the move did not see (morph held the state at the move but no
  -- longer does, the current scene changed since, or a recall or fade
  -- started since, even of the scene current at the move, #584). Such a
  -- move is dropped, never applied over it
  local function move_overtaken()
    return taken_over() and (state.move_held or S.current_scene ~= state.move_scene
      or S.lib.scenes.takeovers() ~= state.move_takeovers)
  end

  -- One apply of the morph's position (exact: at rest, below). With fewer
  -- than two valid corners it flashes the first empty one once per plan
  -- and changes nothing. Otherwise it cancels a running transition, writes
  -- inside deferrable, leaves no scene current and redraws. A move made
  -- after a recall starts again from the recalled state, as after a plan
  -- change. Returns whether values are left
  local function apply_position(exact)
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
    local weights, more = weights_of(plan), false
    S.lib.engine_sync.deferrable(function() more = write_position(plan, weights, exact) end)
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

  -- What the clock does at a tick: "move" (apply the latest position), or,
  -- with no move waiting (a move a recall or fade overtook is dropped),
  -- "rest" while values are left or off their exact blend and nothing took
  -- over, else nil (the clock stops)
  local function next_apply()
    if state.moved and move_overtaken() then state.moved = false end
    if state.moved then return "move" end
    if not taken_over() and (state.pending or rest_due()) then return "rest" end
    return nil
  end

  -- The clock runs while a move waits or values are left: its first apply
  -- on the next tick (a PSET load's hook runs before it), then one each
  -- 1 / apply_hz while the morph moves, and at rest more while values are
  -- left or off their exact blend, unless a recall took over. An error in
  -- an apply ends the clock (it forgets its own id first) and is raised
  -- again
  local function start_clock()
    if S.morph_clock then return end
    S.morph_clock = clock.run(function()
      clock.sleep(0)
      while true do
        local kind = next_apply()
        if not kind then break end
        state.moved = false
        local applied, result = xpcall(function() return apply_position(kind == "rest") end, with_traceback)
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

  -- The morph and morph_y actions: mark a move (and whether morph held the
  -- state, the current scene and the takeover count) and start the clock
  local function note_move()
    state.moved = true
    state.move_held, state.move_scene = not taken_over(), S.current_scene
    state.move_takeovers = S.lib.scenes.takeovers()
    start_clock()
  end

  -- The morph's own params, in the group strata_morph (the menu record
  -- "morph" of lib/params_setup.lua adds them): the position's x, the four
  -- corners' scenes, the position's y. None is a scene field, an LFO
  -- destination or a macro target
  local function percent(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end

  function M.add_params()
    params:add_group("strata_morph", "morph", MORPH.param_count)
    params:add{type = "control", id = "morph", name = "morph",
      controlspec = controlspec.new(0, 1, "lin", 0, 0, ""), formatter = percent, action = note_move}
    for index, corner in ipairs(MORPH.corners) do
      params:add{type = "number", id = "morph_" .. corner, name = "morph " .. corner:upper(), min = 1,
        max = NUM_SCENES, default = index}
    end
    params:add{type = "control", id = "morph_y", name = "morph y",
      controlspec = controlspec.new(0, 1, "lin", 0, 0, ""), formatter = percent, action = note_move}
  end

  -- A PSET load sets the morph and morph_y (their actions start the clock)
  -- with the PSET's own values: nothing applies, and the next move starts
  -- again from the loaded state
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

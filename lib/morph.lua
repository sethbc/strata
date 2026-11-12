-- lib/morph.lua
-- Scene morph (3.4, design §5, the XY morph of §5.5): the params morph and
-- morph_y (the position, x and y), morph_a to morph_d (the four corners'
-- scenes: A at (0, 0), B at (1, 0), C at (0, 1), D at (1, 1)), in the group
-- strata_morph, the plan over the four scenes they name and the clock
-- (S.morph_clock) that applies the latest position. Morph writes params and
-- never recalls: the plan is the scenes' S.lib.scenes.scene_entries paired
-- by id, each continuous value (the counting corners' values weighted by
-- the position) is set through S.lib.scenes.set_value, the setter a
-- transition's step uses (a registered field's own set, a macro's silent
-- one; a quantized freq snaps), and the discrete entries switch to the
-- current corner's through S.lib.scenes.apply_entries' only = "discrete".
-- A corner counts only while its weight is above 0 (ruling 87), so on an
-- edge of the square it is the two-scene morph of that edge, entry for
-- entry; at y = 0 the morph between A and B. Every apply writes inside
-- S.lib.engine_sync.deferrable.
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
  -- morph needs; row_partner and column_partner: the corner beside each on
  -- its row (the same y) and its column (the same x)
  local MORPH = {apply_hz = 10, hysteresis = 0.02, max_values_per_apply = 120, send_threshold = 1 / 1000,
    epsilon = 1e-9, param_count = 6, corners = {"a", "b", "c", "d"}, min_corners = 2,
    row_partner = {a = "b", b = "a", c = "d", d = "c"}, column_partner = {a = "c", b = "d", c = "a", d = "b"}}
  M.MORPH = MORPH

  S.morph_clock = nil

  -- plan: the plan for the scenes and revisions it was built from (nil
  -- until first asked). applied: what the morph last set, corner "a" to
  -- "d" (nil: the next apply takes the corner by weight, as after a plan
  -- change), values by param id, owned (the discrete entries, by key, the
  -- morph set to the current corner's) and the round robin's cursor.
  -- moved: a position waits for the clock; move_held, move_scene and
  -- move_takeovers: whether morph held the state at the latest move, the
  -- current scene then and the scenes' takeover count (a recall or fade
  -- after the move wins over it); pending: the last apply left values for
  -- the next one; flashed: the plan's empty corner has flashed; clock: the
  -- running clock's own token (a clock whose token is gone was retired: it
  -- ends at its next wake and applies nothing)
  local state = {plan = nil, applied = {values = {}, owned = {}, cursor = 1}, moved = false, move_held = false,
    move_scene = 0, move_takeovers = 0, pending = false, flashed = false, clock = nil}

  local function forget_applied()
    state.applied = {corner = nil, values = {}, owned = {}, cursor = 1}
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

  -- Whether values (by corner) differ among the corners listed
  local function differs_among(values, corners)
    for index = 2, #corners do
      if not same_value(values[corners[index]], values[corners[1]]) then return true end
    end
    return false
  end

  -- Whether a slot holds a valid scene
  local function valid_slot(slot)
    local scene = S.scenes[slot]
    return scene ~= nil and scene.populated and validate_scene(scene)
  end

  -- The ramps through 0 (design §10.2): every block with through_zero,
  -- asked from each valid corner's value to each other's. named[from][to]
  -- holds the ids it names for that pair (the corners hold different things
  -- there: a routing's source or destination); switches[from][to] lists
  -- {id, switch} to run at the crossing from one corner to the other
  local function block_ramps(corners, data)
    local ids, named, switches = {}, {}, {}
    for _, from in ipairs(corners) do
      named[from], switches[from] = {}, {}
      for _, to in ipairs(corners) do named[from][to], switches[from][to] = {}, {} end
    end
    for _, record in ipairs(S.registry.scene_blocks) do
      if record.through_zero then
        for _, from in ipairs(corners) do
          for _, to in ipairs(corners) do
            if from ~= to then
              for _, ramp in ipairs(record.through_zero(data[from][record.key], data[to][record.key]) or {}) do
                ids[ramp.id] = true
                named[from][to][ramp.id] = true
                table.insert(switches[from][to], {id = ramp.id, switch = ramp.switch})
              end
            end
          end
        end
      end
    end
    return ids, named, switches
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

  -- Each valid corner's value under the key of an entry, or nil when one
  -- lacks it or holds it as another kind
  local function corner_values(entry, corners, by_key)
    local values = {}
    for _, corner in ipairs(corners) do
      local counterpart = by_key[corner][entry_key(entry)]
      if not (counterpart and counterpart.kind == entry.kind) then return nil end
      values[corner] = counterpart.value
    end
    return values
  end

  -- The plan over the four slots (by corner): the valid corners, in
  -- MORPH.corners' order; the continuous entries that differ between them
  -- (and the ramps' ids, kept whether or not they differ, by id too), as
  -- round robin units in the first valid corner's entry order; per corner,
  -- its discrete entries that differ from another valid corner's, in its
  -- recall order, each with every valid corner's value; the ramps' named
  -- ids and switches per pair. An entry equal in every valid corner, or
  -- missing from one, is left out; which of the rest an apply writes
  -- depends on the corners counting there (counting_corners). ready is
  -- false with fewer than MORPH.min_corners valid corners; empty is then
  -- the first empty or invalid corner's slot
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
    ramp_ids, plan.named, plan.switches = block_ramps(plan.corners, data)
    local items = {}
    plan.ramps, plan.ramp_by_id = {}, {}
    for _, entry in ipairs(lists[plan.corners[1]]) do
      local values = entry.kind == "continuous" and corner_values(entry, plan.corners, by_key)
      if values and ramp_ids[entry.id] then
        local item = plan_item(entry, values)
        table.insert(plan.ramps, item)
        plan.ramp_by_id[entry.id] = item
      elseif values and differs_among(values, plan.corners) then
        table.insert(items, plan_item(entry, values))
      end
    end
    plan.continuous = plan_units(items)
    plan.discrete = {}
    for _, corner in ipairs(plan.corners) do
      plan.discrete[corner] = {}
      for _, entry in ipairs(lists[corner]) do
        local values = entry.kind ~= "continuous" and corner_values(entry, plan.corners, by_key)
        if values and differs_among(values, plan.corners) then
          table.insert(plan.discrete[corner], {entry = entry, key = entry_key(entry), values = values})
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
  -- corner's shared among the valid ones in proportion, so they sum to 1.
  -- Where every valid corner weighs 0 (a far edge or corner whose own
  -- corners are empty) they are the limit from inside the square: a factor
  -- at 0 counts as a vanishing one, so the valid corners with the fewest
  -- such factors share by the product of their others (along a far edge
  -- 1 - x and x, as along the near one; equal shares only at a corner
  -- point of two diagonal corners). Every one 0 with no valid corner
  local function weights_of(plan)
    local x, y = params:get("morph"), params:get("morph_y")
    local factors = {a = {1 - x, 1 - y}, b = {x, 1 - y}, c = {1 - x, y}, d = {x, y}}
    local zeros, products, fewest = {}, {}, nil
    for _, corner in ipairs(plan.corners) do
      local count, product = 0, 1
      for _, factor in ipairs(factors[corner]) do
        if factor == 0 then count = count + 1 else product = product * factor end
      end
      zeros[corner], products[corner] = count, product
      if fewest == nil or count < fewest then fewest = count end
    end
    local total = 0
    for _, corner in ipairs(plan.corners) do
      if zeros[corner] == fewest then total = total + products[corner] end
    end
    local weights = {}
    for _, corner in ipairs(MORPH.corners) do
      weights[corner] = (plan.valid[corner] and zeros[corner] == fewest) and products[corner] / total or 0
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

  -- The corners that count at these weights (ruling 87), in MORPH.corners'
  -- order: the valid corners whose weight is above 0, so inside the square
  -- all four, on an edge its two. At a corner point, where one alone
  -- weighs, its row's other corner counts too (its column's when that one
  -- is empty), so a corner point is the end of its row's two-scene morph
  -- (at y = 0, the morph between A and B at 0 and 1). The current corner
  -- always counts
  local function counting_corners(plan, weights, corner)
    local counted, count, only = {}, 0, nil
    for _, each in ipairs(plan.corners) do
      if weights[each] > 0 then counted[each], count, only = true, count + 1, each end
    end
    if count == 1 then
      local partner = MORPH.row_partner[only]
      if not plan.valid[partner] then partner = MORPH.column_partner[only] end
      if plan.valid[partner] then counted[partner] = true end
    end
    if corner then counted[corner] = true end
    local list = {}
    for _, each in ipairs(MORPH.corners) do
      if counted[each] then list[#list + 1] = each end
    end
    return list
  end

  local function rounded(item, value)
    if item.step then return util.round(value, item.step) end
    return value
  end

  -- The weighted sum of the counting corners' values, as the first's value
  -- plus each other's weighted difference from it (at y = 0, A + x (B - A),
  -- a transition step's arithmetic; on any edge its two-scene morph's); a
  -- corner of weight 1 gives its own value exactly
  local function blend_value(item, weights, counting)
    local base = item.values[counting[1]]
    local value = base
    for _, corner in ipairs(counting) do
      local weight = weights[corner]
      if weight == 1 then return rounded(item, item.values[corner]) end
      if corner ~= counting[1] then value = value + weight * (item.values[corner] - base) end
    end
    return rounded(item, value)
  end

  -- Whether an entry joins an apply (ruling 87): the morph set it before
  -- (it follows its blend back to an edge), or it differs among the
  -- counting corners
  local function item_active(item, counting)
    return state.applied.values[item.id] ~= nil or differs_among(item.values, counting)
  end

  -- A ramp's id's groups among the counting corners (ruling 88): corners
  -- whose through_zero names nothing for the id between them hold the same
  -- thing (a routing's source and destination) and are one group
  local function ramp_groups(plan, id, counting)
    local groups = {}
    for _, corner in ipairs(counting) do
      local home
      for _, group in ipairs(groups) do
        if not plan.named[group[1]][corner][id] then home = group; break end
      end
      if home then home[#home + 1] = corner else groups[#groups + 1] = {corner} end
    end
    return groups
  end

  local function ramp_active(plan, item, counting)
    return item_active(item, counting) or #ramp_groups(plan, item.id, counting) > 1
  end

  -- A ramp through 0 (ruling 88a): with G the current corner's group, m
  -- the largest weight among G's corners and w' the largest among the
  -- counting corners outside G, (sum over G of w x v) x max(0, m - w') / m.
  -- It measures the lead corner against corner, as the corner rule does:
  -- the corner rule leaves G only for the heaviest other corner, which
  -- then outweighs every corner of G, so the value is already 0 wherever G
  -- can be left, and the new group starts at its value times the
  -- hysteresis's lead. It does not depend on which corner of G is the
  -- current one. Two corners that differ: the current one's value times
  -- its lead (at y = 0, A x (1 - 2x) on A's side and B x (2x - 1) on
  -- B's); a group of every counting corner: the plain weighted mean
  local function ramp_value(plan, item, corner, weights, counting)
    local sum, lead, other = 0, 0, 0
    for _, group in ipairs(ramp_groups(plan, item.id, counting)) do
      local member = false
      for _, each in ipairs(group) do member = member or each == corner end
      for _, each in ipairs(group) do
        local weight = weights[each]
        if member then
          sum = sum + weight * item.values[each]
          if weight > lead then lead = weight end
        elseif weight > other then
          other = weight
        end
      end
    end
    if lead <= 0 then return rounded(item, 0) end
    return rounded(item, sum * math.max(0, lead - other) / lead)
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
  -- whole or not at all (a loop pair joins whole when either of it does).
  -- Only entries that join (item_active, ramp_active) are written. Returns
  -- the writes and whether values are left for the next apply
  local function continuous_writes(plan, corner, weights, counting, exact)
    local writes, more = {}, false
    local function add(item, value)
      table.insert(writes, {item = item, value = value})
      state.applied.values[item.id] = value
    end
    for _, item in ipairs(plan.ramps) do
      if ramp_active(plan, item, counting) then
        local value = ramp_value(plan, item, corner, weights, counting)
        if due(item, value, exact) then
          if #writes >= MORPH.max_values_per_apply then more = true else add(item, value) end
        end
      end
    end
    local units, cursor = plan.continuous, state.applied.cursor
    for _ = 1, #units do
      local unit, values, unit_due, joins = units[cursor], {}, false, false
      for _, item in ipairs(unit.members) do joins = joins or item_active(item, counting) end
      if joins then
        for index, item in ipairs(unit.members) do
          values[index] = blend_value(item, weights, counting)
          unit_due = unit_due or due(item, values[index], exact)
        end
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

  -- The discrete entries one apply sets, in the corner's recall order: an
  -- entry the morph set before, when the corner changed from one that
  -- holds it otherwise; one it never set, when it differs among the
  -- counting corners (ruling 87: a hand change to what they agree on
  -- stays). Each becomes owned
  local function discrete_writes(plan, corner, from, counting)
    local owned, list = state.applied.owned, {}
    for _, candidate in ipairs(plan.discrete[corner]) do
      local write
      if owned[candidate.key] then
        write = from ~= nil and from ~= corner and not same_value(candidate.values[corner], candidate.values[from])
      else
        write = differs_among(candidate.values, counting)
      end
      if write then
        list[#list + 1] = candidate.entry
        owned[candidate.key] = true
      end
    end
    return list
  end

  -- Whether, at rest, a value of the current plan is off its exact blend
  -- (an apply that skipped it under the threshold while the morph moved).
  -- A plan rebuilt since the last apply, or none applied, waits for a move
  local function rest_due()
    local plan = state.plan
    local corner = state.applied.corner
    if not (corner and plan and plan.ready and plan_is_current(plan)) then return false end
    local weights = weights_of(plan)
    local counting = counting_corners(plan, weights, corner)
    for _, item in ipairs(plan.ramps) do
      if ramp_active(plan, item, counting) and due(item, ramp_value(plan, item, corner, weights, counting), true) then
        return true
      end
    end
    for _, unit in ipairs(plan.continuous) do
      for _, item in ipairs(unit.members) do
        if item_active(item, counting) and due(item, blend_value(item, weights, counting), true) then return true end
      end
    end
    return false
  end

  -- Each value as a transition's step sets it (S.lib.scenes.set_value,
  -- no recall flag: a quantized freq snaps)
  local function set_values(writes)
    for _, write in ipairs(writes) do S.lib.scenes.set_value(write.item.id, write.value) end
  end

  -- At a crossing from one corner to another: each id their blocks' ramps
  -- name between the two (a routing that differs) and that joins goes to
  -- 0, then its switch runs (an id that is no continuous entry only
  -- switches)
  local function cross(plan, from, corner, counting)
    local zeros, switches, seen = {}, {}, {}
    for _, ramp in ipairs(plan.switches[from][corner]) do
      local item = plan.ramp_by_id[ramp.id]
      if item == nil or ramp_active(plan, item, counting) then
        if item and not seen[item.id] and state.applied.values[item.id] ~= 0 then
          table.insert(zeros, {item = item, value = 0})
          state.applied.values[item.id] = 0
        end
        seen[ramp.id] = true
        if ramp.switch then table.insert(switches, ramp.switch) end
      end
    end
    set_values(zeros)
    for _, switch in ipairs(switches) do switch() end
  end

  -- Write the plan at these weights: at a crossing the ramps whose routing
  -- changes go to 0 and switch; the discrete entries that join switch
  -- (recall order, apply_entries); then the continuous values that join.
  -- Returns whether values are left
  local function write_position(plan, weights, exact)
    local corner, crossed = corner_at(plan, weights)
    local from = state.applied.corner
    local counting = counting_corners(plan, weights, corner)
    if crossed then cross(plan, from, corner, counting) end
    state.applied.corner = corner
    local entries = discrete_writes(plan, corner, from, counting)
    if #entries > 0 then S.lib.scenes.apply_entries(entries, {only = "discrete"}) end
    local writes, more = continuous_writes(plan, corner, weights, counting, exact)
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
  -- (named by S.lib.scenes.label, #641) and changes nothing. Otherwise it
  -- cancels a running transition, writes inside deferrable, leaves no
  -- scene current and redraws. A move made after a recall starts again
  -- from the recalled state, as after a plan change. Returns whether
  -- values are left
  local function apply_position(exact)
    local plan = current_plan()
    if not plan.ready then
      if not state.flashed then
        state.flashed = true
        header_flash(S.lib.scenes.label(plan.empty) .. " empty")
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

  -- End the clock: forget it and what waits (a retired clock ends at its
  -- next wake, applying nothing). cancel: also cancel its coroutine, only
  -- where no resume of it can be waiting to be delivered (cleanup: the
  -- script is ending); a PSET load retires it, since matron may have posted
  -- its resume while Lua read the PSET, and norns' clock.resume raises on a
  -- canceled coroutine (#626)
  local function stop_clock(cancel)
    if cancel and S.morph_clock then clock.cancel(S.morph_clock) end
    S.morph_clock, state.clock = nil, nil
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
  -- on the next tick, then one each 1 / apply_hz while the morph moves, and
  -- at rest more while values are left or off their exact blend, unless a
  -- recall took over. It checks its token after each wait: retired
  -- (stop_clock), it ends at once and touches nothing of a newer clock's.
  -- An error in an apply ends the clock (it forgets its own id first) and
  -- is raised again
  local function start_clock()
    if S.morph_clock then return end
    local token = {}
    state.clock = token
    S.morph_clock = clock.run(function()
      clock.sleep(0)
      while state.clock == token do
        local kind = next_apply()
        if not kind then break end
        state.moved = false
        local applied, result = xpcall(function() return apply_position(kind == "rest") end, with_traceback)
        if not applied then
          S.morph_clock, state.clock = nil, nil
          state.pending = false
          forget_applied()
          error(result, 0)
        end
        state.pending = result
        clock.sleep(1 / MORPH.apply_hz)
      end
      if state.clock == token then
        S.morph_clock, state.clock = nil, nil
        state.pending = false
      end
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
  -- with the PSET's own values: nothing applies (the clock is retired, so
  -- a resume already posted ends it without an apply), and the next move
  -- starts again from the loaded state
  S.register_pset_hook({name = "morph", read = function()
    stop_clock(false)
    forget_applied()
  end})

  S.register_cleanup(S.constants.CLEANUP_ORDER.morph_clock, function()
    stop_clock(true)
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

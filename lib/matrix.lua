-- lib/matrix.lua
-- The modulation matrix (3.4, design §10.2): sixteen routings, each from a
-- modulation source (S.lib.mod_sources: the LFOs, the macros, the
-- recorders, the input level) to one destination of
-- destination_ids() (the LFO destinations but none and the macros) with a
-- bipolar depth. A routing's source and destination are stored by key and
-- id (S.matrix[k] = {source, dest}, "" for none); its depth and on/off are
-- params (matrix_<k>_depth, matrix_<k>: the group strata_matrix, which
-- lib/params_setup.lua's matrix record adds through add_params), so CCs,
-- PSETs, scenes, morph and macros reach them. Beside them, slots 17-22 are
-- the LFOs' home routings (the groundwork before 3.8): LFO n's destination,
-- source lfo<n>, its depth, offset and on/off the LFO's own params. Like the
-- LFOs, the matrix adds offsets around the stored values and never sets a
-- destination param: at each LFO step (S.lib.lfos.on_step) a Lua
-- destination's sum of depth / 100 x normalized(source), and of each
-- playing home's m the LFO does not own (S.lib.lfos.owns: a fast home is
-- its engine node, a macro its own hand-over), becomes one extra offset
-- (clamped once in with_lfo_offsets), a fast destination's sum,
-- with the macros' fast extras (set_fast_extra), goes to the engine as
-- setFastOffset, clamped to -2..2; each send through the LFOs' round robin
-- (mark_due), so inside their cap and deferrable. The routings are stored
-- in scenes (the block matrix, a changed routing ramping through 0), beside
-- each PSET (<path_base>.matrix.data) and in data/strata/matrix.data, all
-- sparse, through S.lib.data_files. Registers the scene fields and block,
-- the PSET hook, the touch hook (learn), the load and save steps, the
-- cleanup step and the "matrix learn" invariant. S.lib.matrix holds the
-- functions and MATRIX (the tunables).

return function(S)
  local M = {}
  local MATRIX_SLOTS = S.constants.MATRIX_SLOTS
  local NUM_VOICES = S.constants.NUM_VOICES

  -- new_depth: the depth a MOD edit gives a routing it completes at 0;
  -- fast_limit: a fast destination's sum is clamped to +-fast_limit half
  -- ranges (the engine clips to the same); note_slot: setFastOffset's (3.4
  -- has one); extra_key: the extra offsets' source key; learn_seconds: how
  -- long learn waits for a touch; save_delay: s from a change of the
  -- routings to the live file's write; max_text: the longest source key or
  -- destination id a stored routing holds; the files' format and names;
  -- never: the param ids no routing reaches (a macro is a source; an LFO
  -- param or a matrix depth would make a loop; morph is never modulated)
  local MATRIX = {
    new_depth = 25,
    fast_limit = 2,
    note_slot = 0,
    extra_key = "matrix",
    learn_seconds = 10,
    save_delay = 0.1,
    max_text = 32,
    data_version = 2,                   -- 2: the LFOs' home routings (the groundwork before 3.8)
    data_floor = 1,                     -- a version 1 file loads with no home routing
    live_file = "matrix.data",          -- in data/strata/
    side_suffix = ".matrix.data",       -- after a PSET's path without .pset
    backup_suffix = ".bak",
    never = {"^macro_%d+$", "^strata_lfo%d+", "^matrix_%d+", "^morph"},
  }
  M.MATRIX = MATRIX

  local function depth_id(k) return "matrix_" .. k .. "_depth" end
  local function on_id(k) return "matrix_" .. k end

  local function is_index(k)
    return type(k) == "number" and k % 1 == 0 and k >= 1 and k <= MATRIX_SLOTS
  end

  -- The LFOs' home routings (the groundwork before 3.8, design §4): LFO n's
  -- at slot MATRIX_SLOTS + n, ROUTINGS slots in all. A home's source is
  -- lfo<n>, fixed; its depth, offset and on/off are the LFO's own params
  local HOMES = S.constants.NUM_LFOS
  local ROUTINGS = MATRIX_SLOTS + HOMES

  local function is_slot(k)
    return type(k) == "number" and k % 1 == 0 and k >= 1 and k <= ROUTINGS
  end

  local function is_lfo(n)
    return type(n) == "number" and n % 1 == 0 and n >= 1 and n <= HOMES
  end

  local function home_slot(n) return MATRIX_SLOTS + n end
  M.home_slot = home_slot

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  -- Slot k with nothing set: no source and destination, a home its lfo<n>
  local function empty_routing(k)
    if k and k > MATRIX_SLOTS then return {source = "lfo" .. (k - MATRIX_SLOTS), dest = ""} end
    return {source = "", dest = ""}
  end

  -- Per routing, its source key and destination id ("" for none); slots
  -- MATRIX_SLOTS + 1 .. ROUTINGS the home routings
  S.matrix = {}
  for k = 1, ROUTINGS do S.matrix[k] = empty_routing(k) end
  S.matrix_learn_clock = nil  -- learn's timeout, while learn waits

  ---------------------------------------------------------------------------
  -- Destinations (design §10.2, Question 33)
  ---------------------------------------------------------------------------

  local function is_control(id)
    local index = params.lookup[id]
    return index ~= nil and params.params[index].t == params.tCONTROL
  end

  local function never_destination(id)
    for _, pattern in ipairs(MATRIX.never) do
      if id:match(pattern) then return true end
    end
    return false
  end

  -- The destinations, built from the LFO destination list and the params
  -- that exist (rebuilt when params are added, so it is read after init):
  -- ids in order, known[id], labels[id]
  local catalog = {count = nil, ids = {}, known = {}, labels = {}}

  local function build_catalog()
    local ids, known, labels = {}, {}, {}
    local function add(id, label)
      if known[id] or never_destination(id) then return end
      ids[#ids + 1] = id
      known[id] = true
      labels[id] = label
    end
    for _, entry in ipairs(S.LFO_DESTINATIONS) do
      local voice = entry.label:match("^v(%d+) main$")
      if voice then
        add("v" .. voice .. "_main", entry.label)
      else
        local id = entry.resolve()
        if id and is_control(id) then add(id, entry.label) end
      end
    end
    catalog = {count = #params.params, ids = ids, known = known, labels = labels}
  end

  local function current_catalog()
    if catalog.count ~= #params.params then build_catalog() end
    return catalog
  end

  -- Every destination id, in the LFO destinations' order: a param id, or
  -- v<i>_main for a voice's main entry (resolved at each step)
  function M.destination_ids()
    local ids = {}
    for index, id in ipairs(current_catalog().ids) do ids[index] = id end
    return ids
  end

  local function destination_known(id) return current_catalog().known[id] == true end
  local function source_known(key) return S.lib.mod_sources.get(key) ~= nil end

  -- A home's destination: any S.LFO_DESTINATIONS key but none, the macros
  -- included (MATRIX.never does not apply to a home)
  local function home_known(id)
    if id == "none" then return false end
    for _, destination in ipairs(S.LFO_DESTINATIONS) do
      if destination.key == id then return true end
    end
    return false
  end
  M.home_known = home_known

  -- The param a destination id modulates now: v<i>_main through
  -- main_param_id (it follows the voice's source), a known id itself; nil
  -- for "" or an id this version has no destination for
  local function resolve(dest)
    if dest == "" or not destination_known(dest) then return nil end
    local voice = dest:match("^v(%d+)_main$")
    if voice then
      local id = main_param_id(tonumber(voice))
      if params.lookup[id] then return id end
      return nil
    end
    return dest
  end

  ---------------------------------------------------------------------------
  -- What plays
  ---------------------------------------------------------------------------

  local function has_params(k) return params.lookup[depth_id(k)] ~= nil end

  -- Both parts set and known
  local function complete(routing)
    return source_known(routing.source) and resolve(routing.dest) ~= nil
  end

  -- Routing k's status (#926, 3.9), derived each time from the routing,
  -- its params and its source's kind, never stored, with the destination
  -- it resolves to and its depth while it plays: "empty" (no part set; a
  -- home with no destination), "incomplete" (one part set), "unknown" (a
  -- part this build lacks, kept: it does not play), "off", "zero" (on at
  -- depth 0, or no params yet: it moves nothing), "summed" (the matrix's
  -- step sums it) or "owned" (it plays in its own engine node or hand-over:
  -- an envelope to a fast destination, the envelopes' route; an LFO's home
  -- on a fast param or a macro, the LFO's). A home's on and depth are its
  -- LFO's (S.lib.lfos.place). nil for no slot k
  local function examine(k)
    if not is_slot(k) then return nil end
    local routing = S.matrix[k]
    if k > MATRIX_SLOTS then
      local n = k - MATRIX_SLOTS
      if routing.dest == "" then return "empty" end
      local id = home_known(routing.dest) and S.lib.lfos.destination(n).resolve()
      if not id then return "unknown" end
      local place = S.lib.lfos.place(n)
      if place == "off" then return "off" end
      if place == "idle" then return "zero" end
      local depth = params:get(S.lib.lfos.param_id(n, "depth"))
      if place == "matrix" then return "summed", id, depth end
      return "owned", id, depth
    end
    if routing.source == "" and routing.dest == "" then return "empty" end
    if routing.source == "" or routing.dest == "" then return "incomplete" end
    local id = source_known(routing.source) and resolve(routing.dest)
    if not id then return "unknown" end
    if not has_params(k) then return "zero" end
    if params:get(on_id(k)) ~= 1 then return "off" end
    local depth = params:get(depth_id(k))
    if depth == 0 then return "zero" end
    if S.lib.envelopes.source_voice(k) and S.lib.lfos.fast_destination(id) then return "owned", id, depth end
    return "summed", id, depth
  end

  function M.status(k)
    return (examine(k))
  end

  -- Routing k's (1-16) resolved destination and depth while it plays
  -- (summed or owned), else nil
  local function playing(k)
    if not is_index(k) then return nil end
    local _, id, depth = examine(k)
    if not id then return nil end
    return id, depth
  end

  -- Routing k's resolved destination and depth while it plays, else nil
  -- (lib/envelopes.lua reads it for the routings it owns)
  function M.playing(k)
    return playing(k)
  end

  -- Whether a playing routing reads the source key
  function M.uses_source(key)
    for k = 1, MATRIX_SLOTS do
      if playing(k) and S.matrix[k].source == key then return true end
    end
    return false
  end

  -- Whether a playing routing or LFO home moves one of the voice's params
  -- (MAIN's ~): the homes 17-22 count as the routings 1-16 do (#881). Each
  -- slot's read (its destination's resolve among it) is contained: one
  -- that raises counts as not playing and prints once per message under
  -- "<the step's label> (affects)", so MAIN's draw goes on (fix round 1)
  local affects_errors, affects_labels, affects_found = {}, {}, false
  for k = 1, ROUTINGS do
    affects_labels[k] = (k > MATRIX_SLOTS and ("matrix home " .. (k - MATRIX_SLOTS)) or ("matrix routing " .. k))
      .. " (affects)"
  end
  local function affects_one(k, voice_text)
    local _, id = examine(k)
    affects_found = id ~= nil and id:match("^v(%d+)_") == voice_text
  end
  function M.affects(voice_idx)
    local voice_text = tostring(voice_idx)
    for k = 1, ROUTINGS do
      affects_found = false
      local ran = S.lib.ui_frame.contained_call(affects_errors, k, affects_labels[k], affects_one, k, voice_text)
      if ran and affects_found then return true end
    end
    return false
  end

  -- Routing k as it stands: {source, dest, depth, on}; nil for no routing
  function M.routing(k)
    if not is_index(k) then return nil end
    local routing = S.matrix[k]
    local depth, on = 0, true
    if has_params(k) then depth, on = params:get(depth_id(k)), params:get(on_id(k)) == 1 end
    return {source = routing.source, dest = routing.dest, depth = depth, on = on}
  end

  ---------------------------------------------------------------------------
  -- The step (design §10.2, Question 36): sums, sends in the round robin
  ---------------------------------------------------------------------------

  -- What the matrix holds: lua[id], the extra offset it set on a Lua
  -- destination (param units); fast[id], true while a fast destination is
  -- tracked (its sum or the value its channel has or will have is not 0);
  -- fast_want[id], what its next send carries (the clamped sum, half
  -- ranges); fast_extras[id][source_key], the macros' LFO extras (half
  -- ranges). What was handed to the send budget is the budget's own answer,
  -- S.lib.engine_sync.expected_value (#647)
  local held = {lua = {}, fast = {}, fast_want = {}, fast_extras = {}}

  -- A fast channel (voice, destination) is one deferrable id of the send
  -- budget (ruling 65): its key, which no param id can be (it holds
  -- spaces, and never starts v<i>_, so a voice sync never forgets it: the
  -- engine's offset node keeps its value), has an engine sender that sends
  -- setFastOffset, so each send goes through send_engine_value, counted,
  -- waiting under the budget with the newest sum winning, and the value
  -- the engine last got is S.engine_param_values[key]. Per fast param id,
  -- {key, send} (send: the round robin's function), made once
  local channels = {}
  for voice = 1, NUM_VOICES do
    for destination = 0, S.constants.NUM_FAST_DESTINATIONS - 1 do
      S.engine_senders["matrix fast " .. voice .. " " .. destination] = function(value)
        engine.setFastOffset(voice - 1, MATRIX.note_slot, destination, value)
      end
    end
  end

  local function channel(id)
    local known = channels[id]
    if known then return known end
    local voice, destination = S.lib.lfos.fast_destination(id)
    local key = "matrix fast " .. voice .. " " .. destination
    known = {key = key, send = function()
      S.lib.engine_sync.send_engine_value(key, held.fast_want[id] or 0)
    end}
    channels[id] = known
    return known
  end

  -- A value's position along a destination's range as its warp places it,
  -- unrounded (a copy of the spec with step 0, made once per spec): what
  -- the LFOs compare, so a move finer than the step counts (#406)
  local unstepped_specs = setmetatable({}, {__mode = "k"})
  local function position(id, value)
    local spec = params:lookup_param(id).controlspec
    local unstepped = unstepped_specs[spec]
    if not unstepped then
      unstepped = spec:copy()
      unstepped.step = 0
      unstepped_specs[spec] = unstepped
    end
    return unstepped:unmap(value)
  end

  -- A Lua destination's send: the value is handed to the budget, which may
  -- keep it waiting
  local function send_lua(id)
    local sync = S.lib.engine_sync
    sync.send_engine_value(id, sync.with_lfo_offsets(id, params:get(id)))
  end

  -- A Lua destination is sent in the round robin under its own id (the
  -- LFOs' key for it too: one send carries every layer); its function is
  -- made once
  local lua_senders = {}
  local function mark_lua(id)
    local send = lua_senders[id]
    if not send then
      send = function() send_lua(id) end
      lua_senders[id] = send
    end
    S.lib.lfos.mark_due(id, send)
  end

  -- Whether a Lua destination's value now moved past the LFOs' threshold
  -- from what the engine has or will have (expected_value: the value
  -- waiting in the send budget, whoever handed it, so a sum back at the
  -- delivered value replaces it; else what the engine last got, which a
  -- voice sync forgets, so the next step sends again), or the engine has
  -- nothing
  local function lua_moved(id)
    local last = S.lib.engine_sync.expected_value(id)
    if last == nil then return true end
    local value = S.lib.engine_sync.with_lfo_offsets(id, params:get(id))
    return math.abs(position(id, value) - position(id, last)) >= S.lib.lfos.LFO.send_threshold
  end

  -- One step's working tables, emptied and reused every step: the sums by
  -- param (Lua and fast apart) and the sorted ids of each kind
  local scratch = {lua_sums = {}, fast_sums = {}, ids = {}}
  -- Per routing and per destination, the error last printed
  -- (contained_call), and the labels its line names, made once
  local step_errors = {routings = {}, destinations = {}, routing_labels = {}, destination_labels = {}}
  for k = 1, MATRIX_SLOTS do step_errors.routing_labels[k] = "matrix routing " .. k end
  for n = 1, HOMES do step_errors.routing_labels[home_slot(n)] = "matrix home " .. n end

  local function destination_label(id)
    local label = step_errors.destination_labels[id]
    if not label then
      label = "matrix destination " .. id
      step_errors.destination_labels[id] = label
    end
    return label
  end

  local function empty(set)
    for key in pairs(set) do set[key] = nil end
  end

  -- scratch.ids: the keys of the given sets, sorted (one order every step)
  local function sorted_ids(first, second)
    local ids = scratch.ids
    for index = #ids, 1, -1 do ids[index] = nil end
    for id in pairs(first) do ids[#ids + 1] = id end
    for id in pairs(second) do
      if first[id] == nil then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
  end

  -- Routing k's m (depth / 100 x the source's normalized value), added to
  -- the sum of the param it reaches, Lua or fast; a value that is not
  -- finite reads 0 (mod_sources.normalized), and an m of 0 reaches nothing.
  -- A routing the envelopes own (an envelope to a fast destination: its
  -- node in the engine plays it, design 3.7 §7.3) is left out
  local function read_routing(k)
    local status, id, depth = examine(k)
    if status ~= "summed" then return end
    local m = depth / 100 * S.lib.mod_sources.normalized(S.matrix[k].source)
    if m ~= 0 and finite(m) then
      local into = S.lib.lfos.fast_destination(id) and scratch.fast_sums or scratch.lua_sums
      into[id] = (into[id] or 0) + m
    end
  end

  -- LFO n's home routing's m (S.lib.lfos.home_m: the LFO's value x depth' /
  -- 100 + its offset), added to the sum of the param its destination
  -- resolves to while the LFO plays, unless the LFO owns it (its engine node
  -- on a fast home, its own step on a macro): the rest is the matrix's,
  -- Lua or fast (a buffer voice's main on its position, ruling 16)
  local function read_home(n)
    local status, id = examine(home_slot(n))
    if status ~= "summed" then return end
    local m = S.lib.lfos.home_m(n)
    if not m or m == 0 or not finite(m) then return end
    local into = S.lib.lfos.fast_destination(id) and scratch.fast_sums or scratch.lua_sums
    into[id] = (into[id] or 0) + m
  end

  -- Whether a Lua destination's send would be heard: its value moved
  -- (lua_moved), and it is not a synced delay's time, which plays its
  -- division (#741)
  local function heard_move(id)
    return lua_moved(id) and not (id == "delay_time" and S.lib.delay_sync.time_unheard())
  end

  -- A Lua destination's sum is its extra offset, sent when its value moved;
  -- one whose sum returns to 0 gives its offset up and is sent once more.
  -- Routings that still play but sum to exactly 0 (they cancel) hold no
  -- offset, so after that one send the destination is sent again only when
  -- its value moves from what the engine has or will have (another layer,
  -- or a voice sync that forgot it), as any other is (#760)
  local function update_lua(id)
    local sync = S.lib.engine_sync
    local m = scratch.lua_sums[id] or 0
    if m ~= 0 then
      local offset = S.lib.lfos.offset_for(id, m)
      sync.set_extra_offset(MATRIX.extra_key, id, offset)
      held.lua[id] = offset
      if heard_move(id) then mark_lua(id) end
    else
      local returning = held.lua[id] ~= nil
      sync.set_extra_offset(MATRIX.extra_key, id, nil)
      held.lua[id] = nil
      if returning or heard_move(id) then mark_lua(id) end
    end
  end

  -- A fast destination's clamped sum is sent when it moved by the
  -- threshold from the value its channel has or will have (expected_value
  -- of its key: the value waiting in the budget, else the one the engine
  -- last got, 0 before any), and once more when it returns to 0 while that
  -- value is another; it is tracked until both are 0
  local function update_fast(id)
    local entry = channel(id)
    local want = util.clamp(scratch.fast_sums[id] or 0, -MATRIX.fast_limit, MATRIX.fast_limit)
    local expected = S.lib.engine_sync.expected_value(entry.key) or 0
    held.fast_want[id] = want
    if math.abs(want - expected) >= S.lib.lfos.LFO.send_threshold or (want == 0 and expected ~= 0) then
      held.fast[id] = true
      S.lib.lfos.mark_due(entry.key, entry.send)
    else
      held.fast[id] = (want ~= 0 or expected ~= 0) or nil
    end
  end

  -- Nothing to do: no routing with both parts set, nothing held, no extra
  local function idle()
    if next(held.lua) or next(held.fast) or next(held.fast_extras) then return false end
    for k = 1, ROUTINGS do
      local routing = S.matrix[k]
      if routing.source ~= "" and routing.dest ~= "" then return false end
    end
    return true
  end

  -- One step, after the LFOs: every destination a playing routing or a
  -- fast extra reaches, and every one the matrix still holds. Each
  -- routing's read and each destination's update is contained: one that
  -- raises is skipped, printing once per message (#517), and every other
  -- routing and destination still plays
  local function step()
    if idle() then return end
    local lua_sums, fast_sums = scratch.lua_sums, scratch.fast_sums
    empty(lua_sums); empty(fast_sums)
    local contained_call = S.lib.ui_frame.contained_call
    for k = 1, MATRIX_SLOTS do
      contained_call(step_errors.routings, k, step_errors.routing_labels[k], read_routing, k)
    end
    for n = 1, HOMES do
      local k = home_slot(n)
      contained_call(step_errors.routings, k, step_errors.routing_labels[k], read_home, n)
    end
    for id, extras in pairs(held.fast_extras) do
      for _, m in pairs(extras) do fast_sums[id] = (fast_sums[id] or 0) + m end
    end
    for _, id in ipairs(sorted_ids(lua_sums, held.lua)) do
      contained_call(step_errors.destinations, id, destination_label(id), update_lua, id)
    end
    for _, id in ipairs(sorted_ids(fast_sums, held.fast)) do
      contained_call(step_errors.destinations, id, destination_label(id), update_fast, id)
    end
  end

  S.lib.lfos.on_step(step)

  -- The matrix's current sum on a param: the extra offset on a Lua
  -- destination (its units), the clamped sum on a fast one (half ranges,
  -- what setFastOffset carries); 0 when nothing reaches it
  function M.offset(param_id)
    return held.lua[param_id] or held.fast_want[param_id] or 0
  end

  -- An LFO on a macro's fast target (lib/macros.lua, design §4.4): m half
  -- ranges under source_key join the destination's setFastOffset sum from
  -- the next step, so one clamp applies; nil (or a value that is not
  -- finite) clears it. Any other param is ignored
  function M.set_fast_extra(source_key, param_id, m)
    if type(source_key) ~= "string" or not S.lib.lfos.fast_destination(param_id) then return end
    local extras = held.fast_extras[param_id]
    if m == nil or not finite(m) then
      if extras then
        extras[source_key] = nil
        if next(extras) == nil then held.fast_extras[param_id] = nil end
      end
      return
    end
    if not extras then
      extras = {}
      held.fast_extras[param_id] = extras
    end
    extras[source_key] = m
  end

  ---------------------------------------------------------------------------
  -- The routings and their files
  ---------------------------------------------------------------------------

  local function is_text(value) return type(value) == "string" and #value <= MATRIX.max_text end

  -- The routings as stored (scenes, PSETs, the live file): sparse, [k] =
  -- {source, dest} for the routings with either part set, a home routing
  -- ({source = "lfo<n>", dest}) only when its destination is
  local function sparse()
    local block = {}
    for k = 1, ROUTINGS do
      local routing = S.matrix[k]
      if (k <= MATRIX_SLOTS and routing.source ~= "") or routing.dest ~= "" then
        block[k] = {source = routing.source, dest = routing.dest}
      end
    end
    return block
  end

  -- What is wrong with a stored block, or nil: a table keyed by routings
  -- 1-16 and the homes 17-22, each {source, dest}, strings of at most
  -- max_text characters, a home's source its LFO's (lfo<n>). A key or id
  -- this version lacks is not wrong (kept verbatim)
  local function block_problem(block)
    if type(block) ~= "table" then return "no table of routings" end
    for k, entry in pairs(block) do
      if not is_slot(k) then return "no routing " .. tostring(k) end
      if type(entry) ~= "table" or not is_text(entry.source) or not is_text(entry.dest) then
        return "routing " .. k .. " is no {source, dest} of at most " .. MATRIX.max_text .. " characters"
      end
      if k > MATRIX_SLOTS and entry.source ~= empty_routing(k).source then
        return "home routing " .. k .. "'s source is not " .. empty_routing(k).source
      end
    end
    return nil
  end

  -- A stored block's routing k ({source, dest}, empty when it holds none;
  -- a home's source is always its LFO's)
  local function stored_routing(block, k)
    local entry = type(block) == "table" and block[k]
    if type(entry) ~= "table" then return empty_routing(k) end
    if k > MATRIX_SLOTS then return {source = empty_routing(k).source, dest = entry.dest or ""} end
    return {source = entry.source or "", dest = entry.dest or ""}
  end

  -- Each LFO whose home routing a load or an apply changed is told
  -- (S.lib.lfos.home_changed), after every routing is in place
  local function tell_homes(before)
    for n = 1, HOMES do
      if S.matrix[home_slot(n)].dest ~= before[n] then S.lib.lfos.home_changed(n) end
    end
  end

  -- Replace every routing and home from a stored block (nil: every one
  -- empty)
  local function load_block(block)
    local before = {}
    for n = 1, HOMES do before[n] = S.matrix[home_slot(n)].dest end
    for k = 1, ROUTINGS do S.matrix[k] = stored_routing(block, k) end
    tell_homes(before)
  end

  -- A console line for every part this version has no source or
  -- destination for (a later release's): kept, saved again, and the
  -- routing does not play
  -- A file load names every unknown part at each load; a scene apply (a
  -- recall, a fade's end, morph's crossing, the scene sequencer's every
  -- recall) names each distinct unknown source key or destination id once
  -- a session, at the first apply that holds it (scene_reported, by kind
  -- and text)
  local scene_reported = {}
  local function report_unknown(path, once_a_session)
    local function report(k, kind, text)
      local seen = kind .. " " .. text
      if once_a_session then
        if scene_reported[seen] then return end
        scene_reported[seen] = true
      end
      local whose = k > MATRIX_SLOTS and ("LFO " .. (k - MATRIX_SLOTS)) or ("routing " .. k)
      print("matrix: " .. path .. ": " .. whose .. "'s " .. kind .. " " .. text
        .. " is unknown here; kept, and it does not play")
    end
    for k = 1, MATRIX_SLOTS do
      local routing = S.matrix[k]
      if routing.source ~= "" and not source_known(routing.source) then report(k, "source", routing.source) end
      if routing.dest ~= "" and not destination_known(routing.dest) then report(k, "destination", routing.dest) end
    end
    for n = 1, HOMES do
      local dest = S.matrix[home_slot(n)].dest
      if dest ~= "" and not home_known(dest) then report(home_slot(n), "destination", dest) end
    end
  end

  -- The files (lib/side_files.lua): the live file data/strata/matrix.data
  -- and the one beside each PSET, {version, matrix = <sparse>}. A file that
  -- cannot be used is set aside and loads no routings; an unknown part
  -- loads, named on the console at each file load. The live file follows
  -- the routings once the start step loaded it (one that failed is never
  -- written over): one write save_delay s after the first change of a
  -- burst, carrying the newest routings, from S.matrix_save_clock; the
  -- cleanup step writes at once
  local files = S.lib.side_files.new({
    name = "matrix", contents = "routings", version = MATRIX.data_version, floor = MATRIX.data_floor, key = "matrix",
    live_file = MATRIX.live_file, side_suffix = MATRIX.side_suffix, backup_suffix = MATRIX.backup_suffix,
    save_delay = MATRIX.save_delay, clock_field = "matrix_save_clock",
    capture = sparse,
    validate = block_problem,
    load = function(block, path)
      load_block(block)
      report_unknown(path)
    end,
  })

  local function routings_changed()
    files.save_live()
    request_redraw()
  end

  -- Set routing k's source key and destination id ("" for none), as a
  -- recall, morph, a PSET load and an edit do: a key or id this version
  -- lacks is kept as it is (it does not play), and the depth is left as it
  -- is. Saves the live file. Returns whether the routing was set
  function M.set_routing(k, source_key, dest_id)
    if not (is_index(k) and is_text(source_key) and is_text(dest_id)) then return false end
    S.matrix[k] = {source = source_key, dest = dest_id}
    S.lib.mutation.note_routing_edit(k)  -- ends a held learn of k (#927)
    routings_changed()
    return true
  end

  -- LFO n's home routing's destination id ("" for none), nil for no LFO n
  function M.home(n)
    if not is_lfo(n) then return nil end
    return S.matrix[home_slot(n)].dest
  end

  -- Set LFO n's home routing's destination ("" for none), as a recall, a
  -- transition's midpoint, morph's crossing, a PSET load and an edit do: an
  -- id this version lacks is kept as it is (it does not play). Saves the
  -- live file, redraws and tells the LFO. Returns whether it was set
  function M.set_home(n, dest_id)
    if not (is_lfo(n) and is_text(dest_id)) then return false end
    local k = home_slot(n)
    local changed = S.matrix[k].dest ~= dest_id
    S.matrix[k] = {source = empty_routing(k).source, dest = dest_id}
    S.lib.mutation.note_routing_edit(k)
    routings_changed()
    if changed then S.lib.lfos.home_changed(n) end
    return true
  end

  -- The LFO page's edit of LFO n's home: "", a known destination or the one
  -- it holds (no 25 % rule: the LFO's depth is its own). Returns whether it
  -- was set
  function M.edit_home(n, dest_id)
    if not is_lfo(n) or type(dest_id) ~= "string" then return false end
    if not (dest_id == "" or dest_id == S.matrix[home_slot(n)].dest or home_known(dest_id)) then return false end
    return M.set_home(n, dest_id)
  end

  -- MOD's edit of routing k (its routing view, its rings, learn): each part
  -- "", a known source or destination, or the part it already holds; a
  -- routing that this completes at depth 0 gets new_depth, so it is heard.
  -- Returns whether the routing was set
  function M.edit_routing(k, source_key, dest_id)
    if not is_index(k) then return false end
    local current = S.matrix[k]
    local function takes(value, stored, known)
      return type(value) == "string" and (value == "" or value == stored or known(value))
    end
    if not (takes(source_key, current.source, source_known) and takes(dest_id, current.dest, destination_known)) then
      return false
    end
    local was_complete = complete(current)
    M.set_routing(k, source_key, dest_id)
    if not was_complete and complete(S.matrix[k]) and has_params(k) and params:get(depth_id(k)) == 0 then
      params:set(depth_id(k), MATRIX.new_depth)
    end
    return true
  end

  -- Empty routing k: no source or destination, depth 0, on
  function M.clear(k)
    if not is_index(k) then return end
    M.set_routing(k, "", "")
    if has_params(k) then
      params:set(depth_id(k), 0)
      set_binary_param(on_id(k), 1)
    end
  end

  ---------------------------------------------------------------------------
  -- Learn (design §10.2, as macro learn §4.5)
  ---------------------------------------------------------------------------

  local learning = nil  -- {k} while learn waits for a touch
  -- Learn's timeout clock's handle (S.lib.clocks, #870;
  -- S.matrix_learn_clock is its id while learn waits): learn ending stops
  -- it through the helper, which retires it near its wake (#626: norns
  -- delivers every resume it posted, and clock.resume raises for a
  -- coroutine it no longer has; at its wake it ends, touching nothing a
  -- newer learn armed) and cancels it earlier, so a burst of learns never
  -- fills matron's 100 clock slots with 10 s sleeps
  local learn_clock = {handle = nil}

  function M.cancel_learn()
    if learn_clock.handle then
      S.lib.clocks.stop(learn_clock.handle)
      learn_clock.handle, S.matrix_learn_clock = nil, nil
    end
    if learning then
      learning = nil
      request_redraw()
    end
  end

  -- Arm learn for routing k's destination: the next hand-touched param that
  -- is a destination becomes it, as a MOD edit; cancel_learn (MOD's K2 in
  -- its view) or learn_seconds without a touch cancels it. Returns
  -- whether it is armed
  function M.learn(k)
    if not is_index(k) then return false end
    M.cancel_learn()
    learning = {k = k}
    local started = S.lib.clocks.run(function(handle)
      if not handle.sleep(MATRIX.learn_seconds) then return end
      learn_clock.handle, S.matrix_learn_clock = nil, nil
      learning = nil
      request_redraw()
    end)
    learn_clock.handle, S.matrix_learn_clock = started, started.id
    request_redraw()
    return true
  end

  -- The routing learn waits for, or nil
  function M.learning() return learning and learning.k or nil end

  -- The destination a touched param is: itself when it is one, else the
  -- main entry of the voice whose main param it is; nil when it is none
  local function learnable(param_id)
    if destination_known(param_id) and not param_id:match("^v%d+_main$") then return param_id end
    for voice_idx = 1, NUM_VOICES do
      local id = "v" .. voice_idx .. "_main"
      if main_param_id(voice_idx) == param_id and destination_known(id) then return id end
    end
    return nil
  end

  -- A learn's rewire is held by the undo on MOD's matrix (#927): the
  -- routing as it was, and the touched param's value from before the touch
  -- (the hooks' third argument)
  local LEARN_UNDO = {page = S.constants.UI_PAGES.index.MOD, section = "matrix"}
  S.register_param_touch(function(param_id, _, before)
    if not learning then return end
    local id = learnable(param_id)
    if not id then
      header_flash("not a destination")
      return
    end
    local k = learning.k
    M.cancel_learn()
    S.lib.mutation.hold_routing(k, LEARN_UNDO, function() M.edit_routing(k, S.matrix[k].source, id) end,
      depth_id(k), param_id, before)
    header_flash("R" .. k .. " > " .. (current_catalog().labels[id] or id))
  end)

  ---------------------------------------------------------------------------
  -- Params, registrations
  ---------------------------------------------------------------------------

  local function signed_percent(param)
    local value = param:get()
    return string.format(value > 0 and "+%.0f%%" or "%.0f%%", value)
  end

  -- The group strata_matrix (the menu record "matrix" of
  -- lib/params_setup.lua adds it): per routing its depth (-100..100 %,
  -- whole percents, 0 at the center; its action notes the edit, as every
  -- param a page randomize draws) and its on/off (on)
  function M.add_params()
    params:add_group("strata_matrix", "matrix", 2 * MATRIX_SLOTS)
    for k = 1, MATRIX_SLOTS do
      params:add{type = "control", id = depth_id(k), name = "R" .. k .. " depth",
        controlspec = controlspec.new(-100, 100, "lin", 1, 0, "%", 1 / 200), formatter = signed_percent,
        action = function() note_param_edit(depth_id(k)) end}
      params:add{type = "binary", behavior = "toggle", id = on_id(k), name = "R" .. k .. " on", default = 1}
    end
  end

  -- The depths crossfade in a transition and morph; the on/off switch at
  -- its end
  for k = 1, MATRIX_SLOTS do
    S.register_scene_field({id = depth_id(k), default = 0})
    S.register_scene_field({id = on_id(k), default = 1, discrete = true})
  end

  -- The scene block: the routings, sparse; discrete, so a fade applies them
  -- at its end, before the depths. A routing whose source or destination
  -- differs ramps its depth through 0 and switches at the midpoint (a
  -- transition) or the crossing (morph), so its old destination never
  -- moves toward the new depth. Its apply names every unknown part (a scene
  -- from a later release) in a console line, saves the live file and asks
  -- for a redraw (morph's crossing applies it outside a recall)
  S.register_scene_block({
    key = "matrix",
    default = function() return {} end,
    capture = sparse,
    validate = function(value) return block_problem(value) == nil end,
    apply = function(value)
      load_block(value)
      report_unknown("a scene", true)
      routings_changed()
    end,
    discrete = true,
    through_zero = function(from, to)
      local ramps = {}
      for k = 1, MATRIX_SLOTS do
        local a, b = stored_routing(from, k), stored_routing(to, k)
        if a.source ~= b.source or a.dest ~= b.dest then
          table.insert(ramps, {id = depth_id(k), switch = function() M.set_routing(k, b.source, b.dest) end})
        end
      end
      -- a home ramps its LFO's depth (strata_lfo<n>_depth, a continuous
      -- scene field)
      for n = 1, HOMES do
        local a, b = stored_routing(from, home_slot(n)), stored_routing(to, home_slot(n))
        if a.dest ~= b.dest then
          table.insert(ramps, {id = S.lib.lfos.param_id(n, "depth"), switch = function() M.set_home(n, b.dest) end})
        end
      end
      return ramps
    end,
  })

  -- The PSET's side file: written with every PSET save (empty too), read
  -- after every PSET load (the depths and on/off are the PSET's own
  -- params), deleted with the PSET
  S.register_pset_hook(files.pset_hook(nil, routings_changed))

  -- The live file: loaded at init, saved at cleanup and as the routings
  -- change, once it was read, missing or set aside. One that could be
  -- neither read nor set aside is never written over (scenes.data's rule):
  -- the routings are not saved in this session, which one line says
  S.register_start(S.constants.START_ORDER.matrix_load, function()
    files.load_live()
    request_redraw()
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.matrix_save, files.save_now)

  -- Cleanup, before the LFOs' step: learn is canceled and the matrix's
  -- offsets (the LFOs' Lua homes' among them) are forgotten. It sends
  -- nothing: norns has freed the engine by then (#461), and the LFOs' step
  -- gives their direct destinations back
  S.register_cleanup(S.constants.CLEANUP_ORDER.matrix, function()
    S.lib.clocks.cancel(learn_clock.handle)  -- the helper's own step cancels what it retired
    M.cancel_learn()
    for id in pairs(held.lua) do S.lib.engine_sync.set_extra_offset(MATRIX.extra_key, id, nil) end
    for _, part in ipairs({"lua", "fast", "fast_want", "fast_extras"}) do
      held[part] = {}
    end
  end)

  -- Learn waits exactly while its timeout clock runs; a retired one (the
  -- helper's) is never S.matrix_learn_clock
  S.register_invariant("matrix learn", function()
    if (learning ~= nil) ~= (S.matrix_learn_clock ~= nil) then
      return "learn waits: " .. tostring(learning ~= nil) .. ", but its clock is " .. tostring(S.matrix_learn_clock)
    end
    if S.matrix_learn_clock and S.lib.clocks.retired[S.matrix_learn_clock] then
      return "the retired learn clock " .. S.matrix_learn_clock .. " is still the learn clock"
    end
  end)

  return M
end

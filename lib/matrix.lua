-- lib/matrix.lua
-- The modulation matrix (3.4, design §10.2): sixteen routings, each from a
-- modulation source (S.lib.mod_sources: the LFOs, the macros, the
-- recorders, the input level) to one destination of
-- destination_ids() (the LFO destinations but none and the macros) with a
-- bipolar depth. A routing's source and destination are stored by key and
-- id (S.matrix[k] = {source, dest}, "" for none); its depth and on/off are
-- params (matrix_<k>_depth, matrix_<k>: the group strata_matrix, which
-- lib/params_setup.lua's matrix record adds through add_params), so CCs,
-- PSETs, scenes, morph and macros reach them. Like the LFOs, the matrix adds
-- offsets around the stored values and never sets a destination param: at
-- each LFO step (S.lib.lfos.on_step) a Lua destination's sum of
-- depth / 100 x normalized(source) becomes one extra offset (summed with
-- the LFOs' and clamped once in with_lfo_offsets), a fast destination's sum,
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
    learn_wake_margin = 0.1,  -- s before its wake a learn clock is still canceled (#626)
    save_delay = 0.1,
    max_text = 32,
    data_version = 1,
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

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function empty_routing() return {source = "", dest = ""} end

  -- Per routing, its source key and destination id ("" for none)
  S.matrix = {}
  for k = 1, MATRIX_SLOTS do S.matrix[k] = empty_routing() end
  S.matrix_learn_clock = nil  -- learn's timeout, while learn waits
  S.matrix_save_clock = nil   -- the live file's coalesced write, while it waits

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

  -- Routing k's resolved destination and depth while it plays (on, both
  -- parts set and known, a depth other than 0), else nil
  local function playing(k)
    if not has_params(k) or params:get(on_id(k)) ~= 1 then return nil end
    local depth = params:get(depth_id(k))
    local routing = S.matrix[k]
    if depth == 0 or not source_known(routing.source) then return nil end
    local id = resolve(routing.dest)
    if not id then return nil end
    return id, depth
  end

  -- Whether a playing routing reads the source key
  function M.uses_source(key)
    for k = 1, MATRIX_SLOTS do
      if playing(k) and S.matrix[k].source == key then return true end
    end
    return false
  end

  -- Whether a playing routing moves one of the voice's params (MAIN's ~)
  function M.affects(voice_idx)
    for k = 1, MATRIX_SLOTS do
      local id = playing(k)
      if id and id:match("^v(%d+)_") == tostring(voice_idx) then return true end
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
  -- tracked (its sum, the value last handed to the budget or the engine's
  -- value is not 0); fast_want[id], what its next send carries (the clamped
  -- sum, half ranges); fast_handed[id], the value last handed to the
  -- budget (it may still wait there); fast_extras[id][source_key], the
  -- macros' LFO extras (half ranges)
  -- lua_handed[id] and lua_handed_over[id], the value a Lua destination's
  -- send last handed to the budget and what the engine had then
  local held = {lua = {}, lua_handed = {}, lua_handed_over = {}, fast = {}, fast_want = {}, fast_handed = {},
    fast_extras = {}}

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
      local value = held.fast_want[id] or 0
      held.fast_handed[id] = value
      S.lib.engine_sync.send_engine_value(key, value)
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

  -- What the engine had (false for nothing) when a value was handed over
  local function engine_seen(id)
    local value = S.engine_param_values[id]
    if value == nil then return false end
    return value
  end

  -- A Lua destination's send: the value is handed to the budget, which may
  -- keep it waiting; lua_handed[id] remembers it, with what the engine had
  -- then (lua_handed_over[id]), until something else reaches the engine
  local function send_lua(id)
    local sync = S.lib.engine_sync
    local value = sync.with_lfo_offsets(id, params:get(id))
    held.lua_handed[id], held.lua_handed_over[id] = value, engine_seen(id)
    sync.send_engine_value(id, value)
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
  -- from what the engine last got (S.engine_param_values: a voice sync
  -- forgets it, so the next step sends again), or the engine got nothing
  -- The reference is the value last handed to the budget while the engine
  -- still has what it had then (that value, or a newer one, may wait in
  -- the budget: a sum back at the delivered value must replace it); once
  -- the engine's value changed (the handed one delivered, a hand edit, a
  -- sync), it is what the engine has
  local function lua_moved(id)
    local last = S.engine_param_values[id]
    if held.lua_handed[id] ~= nil then
      if engine_seen(id) == held.lua_handed_over[id] then
        last = held.lua_handed[id]
      else
        held.lua_handed[id], held.lua_handed_over[id] = nil, nil
      end
    end
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
  -- finite reads 0 (mod_sources.normalized), and an m of 0 reaches nothing
  local function read_routing(k)
    local id, depth = playing(k)
    if not id then return end
    local m = depth / 100 * S.lib.mod_sources.normalized(S.matrix[k].source)
    if m ~= 0 and finite(m) then
      local into = S.lib.lfos.fast_destination(id) and scratch.fast_sums or scratch.lua_sums
      into[id] = (into[id] or 0) + m
    end
  end

  -- A Lua destination's sum is its extra offset, sent when its value moved;
  -- one whose sum returns to 0 gives its offset up and is sent once more
  local function update_lua(id)
    local sync = S.lib.engine_sync
    local m = scratch.lua_sums[id] or 0
    if m ~= 0 then
      local offset = S.lib.lfos.offset_for(id, m)
      sync.set_extra_offset(MATRIX.extra_key, id, offset)
      held.lua[id] = offset
      if lua_moved(id) then mark_lua(id) end
    else
      sync.set_extra_offset(MATRIX.extra_key, id, nil)
      held.lua[id] = nil
      mark_lua(id)
    end
  end

  -- A fast destination's clamped sum is sent when it moved by the
  -- threshold from the value the engine last got (its channel's
  -- S.engine_param_values), and once more when it returns to 0 while the
  -- engine, or the budget, holds another; it is tracked until all three
  -- are 0
  local function update_fast(id)
    local entry = channel(id)
    local want = util.clamp(scratch.fast_sums[id] or 0, -MATRIX.fast_limit, MATRIX.fast_limit)
    local engine_has = S.engine_param_values[entry.key] or 0
    -- only this send hands the channel's key to the budget, so the value
    -- last handed is what the engine has or will have
    local handed = held.fast_handed[id]
    local reference = handed or engine_has
    handed = handed or 0
    held.fast_want[id] = want
    if math.abs(want - reference) >= S.lib.lfos.LFO.send_threshold
        or (want == 0 and (engine_has ~= 0 or handed ~= 0)) then
      held.fast[id] = true
      S.lib.lfos.mark_due(entry.key, entry.send)
    else
      held.fast[id] = (want ~= 0 or engine_has ~= 0 or handed ~= 0) or nil
    end
  end

  -- Nothing to do: no routing with both parts set, nothing held, no extra
  local function idle()
    if next(held.lua) or next(held.fast) or next(held.fast_extras) then return false end
    for k = 1, MATRIX_SLOTS do
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
  -- {source, dest} for the routings with either part set
  local function sparse()
    local block = {}
    for k = 1, MATRIX_SLOTS do
      local routing = S.matrix[k]
      if routing.source ~= "" or routing.dest ~= "" then
        block[k] = {source = routing.source, dest = routing.dest}
      end
    end
    return block
  end

  -- What is wrong with a stored block, or nil: a table keyed by routings
  -- 1-16, each {source, dest}, strings of at most max_text characters. A
  -- key or id this version lacks is not wrong (kept verbatim)
  local function block_problem(block)
    if type(block) ~= "table" then return "no table of routings" end
    for k, entry in pairs(block) do
      if not is_index(k) then return "no routing " .. tostring(k) end
      if type(entry) ~= "table" or not is_text(entry.source) or not is_text(entry.dest) then
        return "routing " .. k .. " is no {source, dest} of at most " .. MATRIX.max_text .. " characters"
      end
    end
    return nil
  end

  -- A stored block's routing k ({source, dest}, empty when it holds none)
  local function stored_routing(block, k)
    local entry = type(block) == "table" and block[k]
    if type(entry) ~= "table" then return empty_routing() end
    return {source = entry.source or "", dest = entry.dest or ""}
  end

  -- Replace every routing from a stored block (nil: every routing empty)
  local function load_block(block)
    for k = 1, MATRIX_SLOTS do S.matrix[k] = stored_routing(block, k) end
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
      print("matrix: " .. path .. ": routing " .. k .. "'s " .. kind .. " " .. text
        .. " is unknown here; kept, and it does not play")
    end
    for k = 1, MATRIX_SLOTS do
      local routing = S.matrix[k]
      if routing.source ~= "" and not source_known(routing.source) then report(k, "source", routing.source) end
      if routing.dest ~= "" and not destination_known(routing.dest) then report(k, "destination", routing.dest) end
    end
  end

  -- Write the routings to path (none too, so a PSET saved over never keeps
  -- an older side file). Returns whether it was written
  local function write_file(path)
    local written, detail = S.lib.data_files.write(path, {version = MATRIX.data_version, matrix = sparse()})
    if not written then print("error: matrix not saved to " .. path .. " (" .. tostring(detail) .. ")") end
    return written
  end

  -- Load the routings from path: a missing file loads them empty; one that
  -- cannot be used is set aside (path .. ".bak", ...) with a console line,
  -- and they load empty. Returns whether path may be written over: false
  -- only for a file that could not be used and could not be set aside
  local function read_file(path)
    local loaded, problem, detail = S.lib.data_files.read(path)
    local why
    if loaded == nil and problem ~= "missing" then
      why = tostring(detail)
    elseif loaded ~= nil then
      if type(loaded) ~= "table" or loaded.version ~= MATRIX.data_version then
        why = "not a version " .. MATRIX.data_version .. " matrix file"
      else
        why = block_problem(loaded.matrix)
      end
    end
    local writable = true
    if why then
      local backup, failure = S.lib.data_files.set_aside(path, MATRIX.backup_suffix)
      print("error loading matrix file " .. path .. ": " .. why .. "; "
        .. (backup and ("kept as " .. backup) or ("not moved: " .. tostring(failure))))
      loaded = nil
      writable = backup ~= nil
    end
    load_block(loaded and loaded.matrix or nil)
    report_unknown(path)
    return writable
  end

  -- The live file follows the routings once it has been loaded (a start
  -- step that failed never overwrites it): one write save_delay s after
  -- the first change of a burst, carrying the newest routings, from
  -- S.matrix_save_clock; the cleanup step writes at once
  local live = {dir = _path.data .. "strata/", loaded = false}

  local function write_live()
    if not live.loaded then return end
    if util.file_exists(live.dir) == false then util.make_dir(live.dir) end
    write_file(live.dir .. MATRIX.live_file)
  end

  local function save_live()
    if not live.loaded or S.matrix_save_clock then return end
    S.matrix_save_clock = clock.run(function()
      clock.sleep(MATRIX.save_delay)
      S.matrix_save_clock = nil
      write_live()
    end)
  end

  local function cancel_save()
    if S.matrix_save_clock then
      clock.cancel(S.matrix_save_clock)
      S.matrix_save_clock = nil
    end
  end

  local function routings_changed()
    save_live()
    request_redraw()
  end

  -- Set routing k's source key and destination id ("" for none), as a
  -- recall, morph, a PSET load and an edit do: a key or id this version
  -- lacks is kept as it is (it does not play), and the depth is left as it
  -- is. Saves the live file. Returns whether the routing was set
  function M.set_routing(k, source_key, dest_id)
    if not (is_index(k) and is_text(source_key) and is_text(dest_id)) then return false end
    S.matrix[k] = {source = source_key, dest = dest_id}
    routings_changed()
    return true
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
  -- Learn ending never cancels its timeout clock once norns may have posted
  -- its resume (#626: norns delivers every resume it posted, and
  -- clock.resume raises for a coroutine it no longer has): within
  -- learn_wake_margin of its wake (at wake) the clock is retired, its token
  -- goes old and at its wake it ends, touching nothing a newer learn armed
  -- (retired[id] until then, which cleanup cancels); earlier it is
  -- canceled, so a burst of learns never fills matron's 100 clock slots
  -- with 10 s sleeps
  local learn_clock = {token = 0, retired = {}, wake = -math.huge}

  function M.cancel_learn()
    if S.matrix_learn_clock then
      if util.time() < learn_clock.wake - MATRIX.learn_wake_margin then
        clock.cancel(S.matrix_learn_clock)  -- its resume cannot be posted yet
      else
        learn_clock.retired[S.matrix_learn_clock] = true
      end
      learn_clock.token = learn_clock.token + 1
      S.matrix_learn_clock = nil
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
    learn_clock.token = learn_clock.token + 1
    local token, id = learn_clock.token, nil
    learn_clock.wake = util.time() + MATRIX.learn_seconds
    id = clock.run(function()
      clock.sleep(MATRIX.learn_seconds)
      learn_clock.retired[id] = nil
      if token ~= learn_clock.token then return end
      S.matrix_learn_clock = nil
      learning = nil
      request_redraw()
    end)
    S.matrix_learn_clock = id
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

  S.register_param_touch(function(param_id)
    if not learning then return end
    local id = learnable(param_id)
    if not id then
      header_flash("not a destination")
      return
    end
    local k = learning.k
    M.cancel_learn()
    M.edit_routing(k, S.matrix[k].source, id)
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
      return ramps
    end,
  })

  -- The PSET's side file: written with every PSET save (empty too), read
  -- after every PSET load (the depths and on/off are the PSET's own
  -- params), deleted with the PSET
  S.register_pset_hook({
    name = "matrix",
    write = function(path_base) write_file(path_base .. MATRIX.side_suffix) end,
    read = function(path_base)
      read_file(path_base .. MATRIX.side_suffix)
      routings_changed()
    end,
    delete = function(path_base) os.remove(path_base .. MATRIX.side_suffix) end,
  })

  -- The live file: loaded at init, saved at cleanup and as the routings
  -- change, once it was read, missing or set aside. One that could be
  -- neither read nor set aside is never written over (scenes.data's rule):
  -- the routings are not saved in this session, which one line says
  S.register_start(S.constants.START_ORDER.matrix_load, function()
    local path = live.dir .. MATRIX.live_file
    live.loaded = read_file(path)
    if not live.loaded then
      print("matrix: " .. path .. " could not be read or moved aside; the routings will not be saved this session")
    end
    request_redraw()
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.matrix_save, function()
    cancel_save()
    write_live()
  end)

  -- Cleanup, before the LFOs' step: learn is canceled and the matrix's
  -- offsets are forgotten. It sends nothing: norns has freed the engine by
  -- then (#461), and the LFOs' step restores their own destinations
  S.register_cleanup(S.constants.CLEANUP_ORDER.matrix, function()
    M.cancel_learn()
    for id in pairs(learn_clock.retired) do clock.cancel(id) end
    learn_clock.retired = {}
    for id in pairs(held.lua) do S.lib.engine_sync.set_extra_offset(MATRIX.extra_key, id, nil) end
    for _, part in ipairs({"lua", "lua_handed", "lua_handed_over", "fast", "fast_want", "fast_handed", "fast_extras"}) do
      held[part] = {}
    end
  end)

  -- Learn waits exactly while its timeout clock runs; a retired one is
  -- never S.matrix_learn_clock and is forgotten when it ends
  S.register_invariant("matrix learn", function()
    if (learning ~= nil) ~= (S.matrix_learn_clock ~= nil) then
      return "learn waits: " .. tostring(learning ~= nil) .. ", but its clock is " .. tostring(S.matrix_learn_clock)
    end
    for id in pairs(learn_clock.retired) do
      local thread = clock.threads and clock.threads[id]
      if id == S.matrix_learn_clock or (clock.threads and (type(thread) ~= "thread" or coroutine.status(thread) == "dead")) then
        return "the retired learn clock " .. id .. " is still the learn clock or has gone but is kept"
      end
    end
  end)

  return M
end

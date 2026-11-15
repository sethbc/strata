-- lib/io/ii.lua
-- The ii bus (3.6 design §6, S.lib.io_ii): the one door for every ii
-- message. The rig's ii_bus says who leads the bus: off (nobody Strata
-- knows of), strata (crow leads when Strata sends) or teletype (a Teletype
-- leads, and Strata only answers its CROW.C1 to C3). Strata sends no ii
-- message unless it leads: the rig says strata and a crow is there. Each
-- message is a line of text, ii.<device>.<command>(<args>), sent through
-- S.lib.io_crow; a bounded queue spreads them over the LFO clock's steps
-- (II.sends_per_step a step, II.queue_max waiting, the newest past it
-- dropped and counted). Leaving the lead ends every device's notes, sends
-- the waiting offs at once (II.cleanup_sends at most), releases each device
-- and only then clears the flag. The devices register with
-- S.register_ii_device; their params form the group strata_out_ii.
-- Notes: docs/notes/lua/io/ii.md

return function(S)
  local M = {}

  local II = {sends_per_step = 4, queue_max = 48, cleanup_sends = 14}
  M.II = II

  local SPEC = {
    bus_key = "ii_bus",
    group = {id = "strata_out_ii", name = "out ii"},
    absent = "[--]", dropped = " dropped", row_label = "bus leader",
    -- Teletype's CROW.C1 to C3 (crow-ii.md §3): each a crow-side function
    -- that tells norns one fixed event; never call4, never a query
    handlers = {
      "ii.self.call1 = function(a) tell('strata_tt1', a) end",
      "ii.self.call2 = function(a, b) tell('strata_tt2', a, b) end",
      "ii.self.call3 = function(a, b, c) tell('strata_tt3', a, b, c) end",
    },
    reset_events = "ii.reset_events(ii.self)",  -- what crow.reset() runs for ii.self (crow-ii.md §1)
    velocity_max = 127, macro_max = 16383,
  }

  -- leading: the flag send reads (set while the rig says strata with a
  -- crow there, cleared only at the end of the leaving sequence); queue:
  -- the lines waiting, each {line, off}
  local state = {started = false, stopped = false, leading = false, queue = {}, dropped = 0, errors = {}}

  local function bus() return S.lib.io_rig.get(SPEC.bus_key) end
  local function present() return S.lib.io_crow.present() end
  local function active() return state.started and not state.stopped end

  function M.leads() return state.leading end
  function M.queued() return #state.queue end
  function M.dropped() return state.dropped end

  -- ii.<device>.<command>(<args>), each argument as crow's lines write numbers
  local function line_for(device, command, ...)
    assert(type(device) == "string" and type(command) == "string", "S.lib.io_ii: a device and a command are strings")
    local args = {}
    for index = 1, select("#", ...) do args[index] = S.lib.io_crow.number((select(index, ...))) end
    return "ii." .. device .. "." .. command .. "(" .. table.concat(args, ", ") .. ")"
  end

  -- The line joins the queue (true), or with queue_max waiting is dropped
  -- and counted (false); false and nothing unless Strata leads
  local function enqueue(off, device, command, ...)
    if not state.leading then return false end
    local line = line_for(device, command, ...)
    if #state.queue >= II.queue_max then
      state.dropped = state.dropped + 1
      request_redraw()
      return false
    end
    table.insert(state.queue, {line = line, off = off})
    return true
  end

  function M.send(device, command, ...) return enqueue(false, device, command, ...) end
  -- An off: a gate low or a note's release, sent first when the lead ends
  function M.send_off(device, command, ...) return enqueue(true, device, command, ...) end

  -- At once, never queued (a device's release): false unless Strata leads
  function M.send_direct(device, command, ...)
    if not state.leading then return false end
    return S.lib.io_crow.send_now(line_for(device, command, ...))
  end

  -- The first sends_per_step waiting, in order, from the LFO clock's step
  S.lib.lfos.on_step(function()
    if not state.leading then return end
    for _ = 1, math.min(II.sends_per_step, #state.queue) do
      S.lib.io_crow.send_now(table.remove(state.queue, 1).line)
    end
  end)

  ---------------------------------------------------------------------------
  -- Leading
  ---------------------------------------------------------------------------

  -- The registered devices, a copy (read at each use)
  local function devices()
    local list = {}
    for index, record in ipairs(S.registry.ii_devices) do list[index] = record end
    return list
  end

  local function call_devices(field)
    for _, record in ipairs(devices()) do
      if record[field] then
        S.lib.ui_frame.contained_call(state.errors, record.name .. " " .. field, "ii device " .. record.name .. " "
          .. field, record[field])
      end
    end
  end

  -- Strata leads: the flag set, then each device made ready
  local function take_lead()
    state.leading = true
    call_devices("ready")
    request_redraw()
  end

  -- The leaving sequence, with the flag still set: each device's notes
  -- ended (their offs join the queue), the queue's offs sent at once in
  -- order (cleanup_sends at most, the rest dropped), each device released,
  -- then the flag cleared and anything a release queued dropped
  local function give_up_lead()
    if not state.leading then return end
    local targets = S.lib.io_targets
    if targets and targets.end_target then
      for _, record in ipairs(devices()) do targets.end_target(record.name) end
    end
    local waiting, sent = state.queue, 0
    state.queue = {}
    for _, entry in ipairs(waiting) do
      if entry.off and sent < II.cleanup_sends then
        S.lib.io_crow.send_now(entry.line)
        sent = sent + 1
      end
    end
    call_devices("release")
    state.leading = false
    state.queue = {}
    request_redraw()
  end

  -- The crow left: nothing to send it through
  local function crow_gone()
    state.queue = {}
    state.leading = false
  end

  local function send_handlers()
    for _, line in ipairs(SPEC.handlers) do S.lib.io_crow.send_now(line) end
  end

  -- What the bus setting asks of a crow just set up (or there at the start)
  local function set_up()
    if not (active() and present()) then return end
    local leader = bus()
    if leader == "strata" then take_lead()
    elseif leader == "teletype" then send_handlers() end
  end

  S.lib.io_crow.on_setup("ii", set_up)
  S.lib.io_crow.on_gone("ii", crow_gone)

  S.lib.io_rig.on_change(SPEC.bus_key, function(value, previous)
    if not active() then return end
    if previous == "strata" then give_up_lead() end
    if previous == "teletype" and present() then S.lib.io_crow.send_now(SPEC.reset_events) end
    if value == "strata" and present() then take_lead()
    elseif value == "teletype" and present() then send_handlers() end
  end)

  ---------------------------------------------------------------------------
  -- Teletype's three calls (design §6.4), each to a shared action
  ---------------------------------------------------------------------------

  local function ignored(call, why)
    print("strata: teletype " .. call .. " ignored: " .. why)
  end

  local function whole_in(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
  end

  local function answering() return active() and bus() == "teletype" end

  S.lib.io_crow.on_event("strata_tt1", function(n)
    if answering() then S.lib.io_actions.recall_scene(n) end
  end)

  S.lib.io_crow.on_event("strata_tt2", function(voice, mode)
    if answering() then S.lib.io_actions.run_voice(voice, mode) end
  end)

  local CALL3 = {
    function(voice, x)
      if not whole_in(x, 0, SPEC.velocity_max) then
        return ignored("call3", "velocity " .. tostring(x) .. " is not 0 to " .. SPEC.velocity_max)
      end
      S.lib.io_actions.retrigger(voice, x / SPEC.velocity_max)
    end,
    function(voice, x) S.lib.io_actions.freeze(voice, x) end,
    function(voice, x) S.lib.io_actions.mute(voice, x) end,
    function(m, x)
      if not whole_in(x, 0, SPEC.macro_max) then
        return ignored("call3", "macro value " .. tostring(x) .. " is not 0 to " .. SPEC.macro_max)
      end
      S.lib.io_actions.macro(m, x / SPEC.macro_max)
    end,
    function(_, x) S.lib.io_actions.patterns(x) end,
  }

  S.lib.io_crow.on_event("strata_tt3", function(k, v, x)
    if not answering() then return end
    local action = whole_in(k, 1, #CALL3) and CALL3[k] or nil
    if not action then return ignored("call3", "k " .. tostring(k) .. " is not 1 to " .. #CALL3) end
    action(v, x)
  end)

  ---------------------------------------------------------------------------
  -- Params: the devices' (PSET-only, group strata_out_ii)
  ---------------------------------------------------------------------------

  function M.add_params()
    local count = 0
    for _, record in ipairs(devices()) do count = count + record.param_count end
    if count == 0 then return end
    params:add_group(SPEC.group.id, SPEC.group.name, count)
    for _, record in ipairs(devices()) do
      if record.add_params then record.add_params() end
    end
  end

  ---------------------------------------------------------------------------
  -- IO's ii section
  ---------------------------------------------------------------------------

  -- The bus row turned as a user turns it (ruling 26): the section shown,
  -- E2 to the row, E3 to value; raises when the page cannot get there
  local function turn_bus(value)
    local values = S.lib.io_rig.RIG.specs[SPEC.bus_key].values
    local function index_of(choice)
      for index, name in ipairs(values) do
        if name == choice then return index end
      end
      error("ii layout: no bus setting " .. tostring(choice), 3)
    end
    S.lib.pages_io.show_section("ii")
    local rows = S.lib.pages_io.rows()
    local target
    for index, row in ipairs(rows) do
      if row.section == "ii" and row.key == SPEC.bus_key then target = index end
    end
    if not target then error("ii layout: the IO page has no ii row for " .. SPEC.bus_key, 2) end
    local from = S.io_cursor
    local moves = 0
    for index = math.min(from, target), math.max(from, target) do
      if rows[index].selectable ~= false and index ~= from then moves = moves + 1 end
    end
    enc(2, target >= from and moves or -moves)
    local row = S.lib.pages_io.rows()[S.io_cursor]
    if not (row and row.section == "ii" and row.key == SPEC.bus_key) then
      error("ii layout: E2 did not reach the " .. SPEC.bus_key .. " row", 2)
    end
    enc(3, index_of(value) - index_of(bus()))
    if bus() ~= value then error("ii layout: E3 did not set the bus to " .. value, 2) end
  end

  local function layout_state(name, leader, sends)
    return {name = name, setup = function(context)
      if leader then context.crow.plug() end
      if leader and leader ~= "off" then turn_bus(leader) end
      for k = 1, sends or 0 do M.send("layout", "probe", k) end
    end}
  end

  S.register_io_section({name = "ii", title = "ii",
    rows = function() return {{label = SPEC.row_label, kind = "rig", key = SPEC.bus_key}} end,
    status = function()
      if not present() then return SPEC.absent end
      if state.dropped > 0 then return state.dropped .. SPEC.dropped end
      return nil
    end,
    layout_states = {
      layout_state("without a crow"),
      layout_state("a crow, the bus off", "off"),
      layout_state("Strata leads", "strata"),
      layout_state("Teletype leads", "teletype"),
      layout_state("messages dropped", "strata", II.queue_max + 2),
    }})

  ---------------------------------------------------------------------------
  -- Start and cleanup
  ---------------------------------------------------------------------------

  -- With a crow already there (crow's own start step has set it up), what
  -- the bus asks: the lead taken, or Teletype's handlers sent
  S.register_start(S.constants.START_ORDER.io_ii, function()
    state.started = true
    set_up()
  end)

  -- The cleanup step: the leaving sequence while Strata leads (the targets'
  -- step has ended every note, so their offs wait in the queue), then
  -- nothing more is sent
  function M.stop()
    if state.stopped then return end
    give_up_lead()
    state.stopped = true
    state.queue = {}
  end

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_ii, function() M.stop() end)

  return M
end

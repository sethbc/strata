-- lib/io/ii.lua
-- The ii bus (3.6 design §6, S.lib.io_ii): the one door for every ii
-- message. The rig's ii_bus says who leads the bus: off (nobody Strata
-- knows of), strata (crow leads when Strata sends) or teletype (a Teletype
-- leads, and Strata only answers its CROW.C1 to C3). Strata sends no ii
-- message unless it leads: the rig says strata and a crow is there. Each
-- message is a line of text, ii.<device>.<command>(<args>), sent through
-- S.lib.io_crow; a bounded queue spreads them over the LFO clock's steps
-- (II.sends_per_step a step, II.queue_max waiting, a send past it dropped
-- and counted; an off is queued exactly when its line owes one, never
-- dropped). Under sustained overload the lines (a device's port, or a
-- device's command) take turns (#710): from a refusal until the queue next
-- empties, a line's first send in a step decides for one note of it, that
-- note admitted whole only within its share and with room for a note for
-- each line served less recently; nothing admitted is ever displaced.
-- Leaving the lead ends every device's notes, sends the waiting offs at
-- once (II.cleanup_sends at most, the rest owed), releases each device
-- (II.leave_lines in all at once) and only then clears the flag. An off
-- that cannot go (past the fourteenth, or crow gone) is owed, and the next
-- lead queues it after the devices' ready. The devices register with
-- S.register_ii_device; their params form the group strata_out_ii.
-- Notes: docs/notes/lua/io/ii.md

return function(S)
  local M = {}

  -- leave_lines: everything the leaving sequence sends at once, its offs
  -- and the releases' lines (design §3.4: inside crow's 16); asked_steps:
  -- how long a line counts as asking after its latest send (a second of
  -- LFO steps), share_factor: the share's divisor per asking line,
  -- note_lines: the most lines a note sends (a TELEXo envelope note's cv,
  -- env and tr), the room a pressed decision asks for each note (#710)
  local II = {sends_per_step = 4, queue_max = 48, cleanup_sends = 14, leave_lines = 15, asked_steps = 48,
    share_factor = 2, note_lines = 3}
  M.II = II

  local SPEC = {
    bus_key = "ii_bus",
    group = {id = "strata_out_ii", name = "out ii"}, unused_name = "unused",
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
    -- #710's turns: the devices whose every command with an argument takes
    -- the port it addresses first (crow-ii.md §2: the ER-301's tr, cv and
    -- the rest; the TELEXo's tr, cv, env and the rest; their global
    -- commands take none), so a port is one line from the start (moving
    -- this into a device's registration is #717); the command that starts
    -- a note on them (each sends a note's tr last), and a note's first
    -- send (its pitch)
    port_devices = {er301 = true, txo = true}, note_trigger = "tr", note_pitch = "cv",
  }

  -- leading: the flag send reads (set while the rig says strata with a
  -- crow there, cleared only at the end of the leaving sequence); queue:
  -- the entries waiting, each {line, off, pair, key, turn}; pairs: the
  -- (device, command) pairs that have had an off this lead; lines: their
  -- lines' state ({high, waiting}, by key); owed: the offs the next lead
  -- queues first after the devices' ready ({order = {entry, ...}, by_key});
  -- owing: crow left while Strata led, so an off that comes before the next
  -- lead is owed; leave_room: the lines the leaving sequence may still send.
  -- The turns (#710): step, the LFO steps counted while Strata leads;
  -- turns, each line's turn by its id; asking, how many turns asked within
  -- the last asked_steps; wanting, the turns refused since they were last
  -- served; refusals, the count that orders them; pressed, from a refusal
  -- until the queue next empties
  local state = {started = false, stopped = false, leading = false, queue = {}, lines = {}, pairs = {}, dropped = 0,
    errors = {}, owed = {order = {}, by_key = {}}, owing = false, leave_room = nil,
    step = 0, turns = {}, asking = 0, wanting = {}, refusals = 0, pressed = false}

  local function bus() return S.lib.io_rig.get(SPEC.bus_key) end
  local function present() return S.lib.io_crow.present() end
  local function active() return state.started and not state.stopped end

  function M.leads() return state.leading end
  function M.queued() return #state.queue end
  function M.dropped() return state.dropped end
  function M.owed() return #state.owed.order end
  -- For tests: the owed offs' lines, in order
  function M.owed_lines()
    local lines = {}
    for index, entry in ipairs(state.owed.order) do lines[index] = entry.line end
    return lines
  end

  -- ii.<device>.<command>(<args>), each argument as crow's lines write numbers
  local function line_for(device, command, ...)
    assert(type(device) == "string" and type(command) == "string", "S.lib.io_ii: a device and a command are strings")
    local args = {}
    for index = 1, select("#", ...) do args[index] = S.lib.io_crow.number((select(index, ...))) end
    return "ii." .. device .. "." .. command .. "(" .. table.concat(args, ", ") .. ")"
  end

  local function count_drop()
    state.dropped = state.dropped + 1
    request_redraw()
  end

  -- A queued entry: its text, whether it is an off, and its line's key
  -- (the device, the command and the first argument, the port or output:
  -- ii.er301.tr(3, 1) and ii.er301.tr(3, 0) are one line), with its device,
  -- command and first argument ("" with none) for its turn
  local function entry_for(off, device, command, ...)
    local first = select("#", ...) > 0 and S.lib.io_crow.number((...)) or ""
    local pair = device .. "\n" .. command
    return {line = line_for(device, command, ...), off = off, pair = pair, key = pair .. "\n" .. first,
      device = device, command = command, first = first}
  end

  -- Per line while Strata leads (build ruling 24), only for the (device,
  -- command) pairs that have had an off this lead (state.pairs): high
  -- (true: a send of it reached crow since its last off; false: its off
  -- did, and nothing raised it since; nil: unknown, it may have gone high
  -- before its pair was learned) and waiting (its sends in the queue).
  -- Lines that never take an off (play_note, cv, mode) keep nothing
  local function line_state(key)
    local line = state.lines[key]
    if not line then
      line = {high = nil, waiting = 0}
      state.lines[key] = line
    end
    return line
  end

  local function forget_lines() state.lines, state.pairs = {}, {} end

  -- Learn a pair at its first off: its sends already waiting are counted
  -- now. An early send left uncounted would, as it drains, use up the
  -- count of a later send of its line, which would then read as low with
  -- nothing waiting while that send still waits
  local function learn_pair(entry)
    local pair = entry.pair
    state.pairs[pair] = true
    for _, waiting in ipairs(state.queue) do
      if waiting.pair == pair and not waiting.off then
        local line = line_state(waiting.key)
        line.waiting = line.waiting + 1
      end
    end
  end

  -- For tests: how many lines the module keeps state for
  function M.lines_kept()
    local count = 0
    for _ in pairs(state.lines) do count = count + 1 end
    return count
  end

  ---------------------------------------------------------------------------
  -- Turns (#710): under sustained overload the lines take turns
  ---------------------------------------------------------------------------

  -- A send's turn is its line: its device and the port it addresses (its
  -- first argument) for a device whose commands address ports
  -- (SPEC.port_devices), so a port's
  -- cv, tr, env and settings share one turn; else its device and command
  -- (its pair), so play_note takes one turn for all its pitches. The two
  -- kinds of id cannot meet: a port's has an empty command. Each turn:
  -- waiting (its sends in the queue), served (the step its latest send went
  -- to crow, nil never), asked (the step of its latest send), asking
  -- (counted in state.asking), wanting (the refusal that put it in
  -- state.wanting, nil when not there), and the step's decision: decided
  -- (the step), admitted (true or false) and closed (its note done: a
  -- port's trigger, or a device-and-command line's first send, admitted)
  local function turn_for(entry)
    local id = entry.pair
    if SPEC.port_devices[entry.device] and entry.first ~= "" then id = entry.device .. "\n\n" .. entry.first end
    local turn = state.turns[id]
    if not turn then
      turn = {id = id, waiting = 0, served = nil, asked = nil, asking = false, wanting = nil,
        decided = nil, admitted = false, closed = false}
      state.turns[id] = turn
    end
    return turn
  end

  local function forget_turns()
    state.turns, state.asking, state.wanting, state.pressed = {}, 0, {}, false
  end

  local function ask(turn)
    turn.asked = state.step
    if not turn.asking then
      turn.asking = true
      state.asking = state.asking + 1
    end
  end

  -- A line's share of the queue: queue_max over share_factor times the lines
  -- asking (asked within the last asked_steps), never less than one
  local function share()
    return math.max(1, math.floor(II.queue_max / (II.share_factor * math.max(1, state.asking))))
  end

  -- True when a was served less recently than b: never before ever, then the
  -- earlier step, and between two never served the one refused first
  local function served_before(a, b)
    if a.served == nil then
      if b.served ~= nil then return true end
      return a.wanting ~= nil and (b.wanting == nil or a.wanting < b.wanting)
    end
    return b.served ~= nil and a.served < b.served
  end

  -- A line's first send in a step decides: admitted while fewer than
  -- queue_max wait; while the queue is pressed, only with fewer than its
  -- share of lines waiting, and with room for a note (II.note_lines) for it
  -- and for each wanting line with nothing waiting that was served less
  -- recently than it
  local function decides(turn)
    if #state.queue >= II.queue_max then return false end
    if not state.pressed then return true end
    if turn.waiting >= share() then return false end
    local held = 0
    for other in pairs(state.wanting) do
      if other ~= turn and other.waiting == 0 and served_before(other, turn) then held = held + 1 end
    end
    return II.queue_max - #state.queue >= (held + 1) * II.note_lines
  end

  -- The line's later sends in the step follow its decision, within the
  -- bound. While pressed the decision covers one note of the line: a
  -- port's note stays open until its first admitted trigger (a re-pitch or
  -- a setting before it closes nothing), a device-and-command line (the
  -- play_note kind) closes at its first admitted send, and after that the
  -- line's later sends in the step are refused. A pitch after an earlier
  -- send of the line in the step begins a note (after a re-pitch or a
  -- setting): with room for less than a note (II.note_lines) it and the
  -- rest of the line in the step are refused, so the note goes whole
  local function admits(turn, command)
    if turn.decided ~= state.step then
      turn.decided, turn.admitted, turn.closed = state.step, decides(turn), false
      return turn.admitted
    end
    if not turn.admitted or #state.queue >= II.queue_max then return false end
    if not state.pressed then return true end
    if turn.closed then return false end
    if command == SPEC.note_pitch and II.queue_max - #state.queue < II.note_lines then
      turn.admitted = false
      return false
    end
    return true
  end

  local function refuse(turn)
    if not turn.wanting then
      state.refusals = state.refusals + 1
      turn.wanting = state.refusals
      state.wanting[turn] = true
    end
    state.pressed = true
    count_drop()
  end

  -- A sent entry's turn is served; at each step the turns that have not
  -- asked within asked_steps stop asking (and wanting), and are forgotten
  -- with nothing waiting
  local function served(turn)
    turn.waiting = turn.waiting - 1
    turn.served = state.step
    turn.wanting = nil
    state.wanting[turn] = nil
  end

  local function age_turns()
    for id, turn in pairs(state.turns) do
      if turn.asking and turn.asked <= state.step - II.asked_steps then
        turn.asking = false
        state.asking = state.asking - 1
        turn.wanting = nil
        state.wanting[turn] = nil
      end
      if not turn.asking and turn.waiting == 0 then state.turns[id] = nil end
    end
  end

  -- The line joins the queue (true), or is refused, dropped and counted
  -- (false): with queue_max waiting, or by its line's decision for the
  -- step, or while pressed as a later note of the line in the step;
  -- false and nothing unless Strata leads. A line queued here is never
  -- taken out again while Strata leads
  function M.send(device, command, ...)
    if not state.leading then return false end
    local entry = entry_for(false, device, command, ...)
    local turn = turn_for(entry)
    ask(turn)
    if not admits(turn, command) then
      refuse(turn)
      return false
    end
    if command == SPEC.note_trigger or turn.id == entry.pair then turn.closed = true end
    entry.turn = turn
    turn.waiting = turn.waiting + 1
    table.insert(state.queue, entry)
    if state.pairs[entry.pair] then
      local line = line_state(entry.key)
      line.waiting = line.waiting + 1
    end
    return true
  end

  -- An off (a gate low or a note's release) is queued exactly when its
  -- line owes one (build ruling 24): the pair's first off this lead (the pair is
  -- learned then), or a line that is high, unknown, or has a send waiting.
  -- An owed off joins the end of the queue whatever its length (it never
  -- displaces a line and is never dropped), unless the newest waiting
  -- entry of its line is already an off: then nothing is added; true
  -- either way. An off for a line known low (its on was dropped at a full
  -- queue) adds nothing, is not counted, false. False and nothing unless
  -- Strata leads. While crow is away after a lead (owing), an off for a
  -- line not known low is kept as owed instead (false)
  local function known_low(entry)
    if not state.pairs[entry.pair] then return false end
    local line = state.lines[entry.key]
    return line ~= nil and line.high == false and line.waiting == 0
  end

  -- An off the next lead owes, once per line (the first kept: an off's text
  -- is its line's)
  local function owe(entry)
    if state.owed.by_key[entry.key] then return end
    state.owed.by_key[entry.key] = entry
    table.insert(state.owed.order, entry)
  end

  -- An owed off joins the end of the queue (the pair learned at its first),
  -- unless the newest waiting entry of its line is already an off
  local function queue_off(entry)
    if not state.pairs[entry.pair] then learn_pair(entry) end
    for index = #state.queue, 1, -1 do
      local waiting = state.queue[index]
      if waiting.key == entry.key then
        if waiting.off then return end
        break
      end
    end
    table.insert(state.queue, entry)
  end

  function M.send_off(device, command, ...)
    if not state.leading then
      if state.owing and not state.stopped then
        local entry = entry_for(true, device, command, ...)
        if not known_low(entry) then owe(entry) end
      end
      return false
    end
    local entry = entry_for(true, device, command, ...)
    if known_low(entry) then return false end
    queue_off(entry)
    return true
  end

  -- At once, never queued (a device's release): false unless Strata leads;
  -- in the leaving sequence, only while its total is under II.leave_lines
  -- (false and dropped past it)
  function M.send_direct(device, command, ...)
    if not state.leading then return false end
    local line = line_for(device, command, ...)
    if state.leave_room then
      if state.leave_room <= 0 then return false end
      state.leave_room = state.leave_room - 1
    end
    return S.lib.io_crow.send_now(line)
  end

  -- The first sends_per_step waiting, in order, from the LFO clock's step;
  -- each sent entry of a learned pair moves its line's state (a send
  -- raises it, an off lowers it; a line known low is kept, so its next off
  -- is not owed unless something raises it); each sent send's turn served,
  -- the press ended when the queue is empty, and the turns aged
  S.lib.lfos.on_step(function()
    if not state.leading then return end
    state.step = state.step + 1
    for _ = 1, math.min(II.sends_per_step, #state.queue) do
      local entry = table.remove(state.queue, 1)
      S.lib.io_crow.send_now(entry.line)
      if entry.turn then served(entry.turn) end
      if state.pairs[entry.pair] then
        local line = line_state(entry.key)
        if entry.off then
          line.high = false
        else
          -- a pair's waiting sends are counted when it is learned and every
          -- later one as it joins, so the count is exact: a short one is a
          -- bug (the line is marked high first: its send has gone)
          line.high = true
          assert(line.waiting > 0, "S.lib.io_ii: a sent line's count of waiting sends is short")
          line.waiting = line.waiting - 1
        end
      end
    end
    if #state.queue == 0 then state.pressed = false end
    age_turns()
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

  -- Strata leads: the flag set, a new lead knowing nothing of the lines,
  -- then each device made ready, then the owed offs queued (never refused
  -- or dropped) and the store emptied. Once only: a second crow plugged in
  -- calls norns.crow.add again with no remove, and its setup leaves the
  -- lead and the queue as they are
  local function take_lead()
    if state.leading then return end
    state.leading = true
    forget_lines()
    forget_turns()
    call_devices("ready")
    local owed = state.owed.order
    state.owed, state.owing = {order = {}, by_key = {}}, false
    for _, entry in ipairs(owed) do queue_off(entry) end
    request_redraw()
  end

  -- The leaving sequence, with the flag still set: each device's notes
  -- ended (their offs join the queue), the queue's offs sent at once in
  -- order (cleanup_sends at most, the rest owed to the next lead), each
  -- device released (its lines sent while the sequence's total stays at
  -- most leave_lines, the rest dropped), then the flag cleared and
  -- anything a release queued dropped
  local function give_up_lead()
    if not state.leading then return end
    local targets = S.lib.io_targets
    if targets and targets.end_target then
      for _, record in ipairs(devices()) do targets.end_target(record.name) end
    end
    local waiting, sent = state.queue, 0
    state.queue = {}
    forget_turns()
    for _, entry in ipairs(waiting) do
      if entry.off then
        if sent < II.cleanup_sends then
          S.lib.io_crow.send_now(entry.line)
          sent = sent + 1
        else
          owe(entry)
        end
      end
    end
    state.leave_room = II.leave_lines - sent
    call_devices("release")
    state.leave_room = nil
    state.leading = false
    state.queue = {}
    forget_lines()
    forget_turns()
    request_redraw()
  end

  -- The crow left while Strata led: nothing to send it through. The
  -- waiting offs are owed; the waiting sends never reached the device, so
  -- each line keeps only what crow got (high, low or unknown), and an off
  -- that comes before the next lead is owed unless its line is known low
  local function crow_gone()
    if not state.leading then return end
    for _, entry in ipairs(state.queue) do
      if entry.off then owe(entry) end
    end
    state.queue = {}
    forget_turns()
    for _, line in pairs(state.lines) do line.waiting = 0 end
    state.leading, state.owing = false, true
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

  -- Each device's add_params, contained (build ruling 15), and the group kept
  -- whole: a device that added fewer params than its param_count (it
  -- raised, or miscounted) has the rest filled with hidden separators
  -- <device>_unused_<n>, so the next device's params stay in the group; one
  -- that added more cannot be mended. Either prints one line
  local function add_device_params(record)
    local before = #params.params
    if record.add_params then
      S.lib.ui_frame.contained_call(state.errors, record.name .. " add_params", "ii device " .. record.name
        .. " add_params", record.add_params)
    end
    local added, declared = #params.params - before, record.param_count
    if added < declared then
      for n = 1, declared - added do
        local id = record.name .. "_unused_" .. n
        params:add_separator(id, SPEC.unused_name)
        params:hide(id)
      end
      print("strata: ii device " .. record.name .. " added " .. added .. " of its " .. declared .. " params: "
        .. (declared - added) .. " hidden in their place")
    elseif added > declared then
      print("strata: ii device " .. record.name .. " added " .. added .. " params, more than its " .. declared
        .. ": the out ii group ends before the last " .. (added - declared))
    end
  end

  function M.add_params()
    local count = 0
    for _, record in ipairs(devices()) do count = count + record.param_count end
    if count == 0 then return end
    params:add_group(SPEC.group.id, SPEC.group.name, count)
    for _, record in ipairs(devices()) do add_device_params(record) end
  end

  ---------------------------------------------------------------------------
  -- IO's ii section
  ---------------------------------------------------------------------------

  -- The bus row turned as a user turns it (plan ruling 26): the cursor put on
  -- the row by S.lib.pages_io.go_to_row, E3 to value; raises when the page
  -- cannot get there
  local function turn_bus(value)
    local values = S.lib.io_rig.RIG.specs[SPEC.bus_key].values
    local function index_of(choice)
      for index, name in ipairs(values) do
        if name == choice then return index end
      end
      error("ii layout: no bus setting " .. tostring(choice), 3)
    end
    S.lib.pages_io.go_to_row("ii", "ii", {key = SPEC.bus_key})
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

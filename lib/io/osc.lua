-- lib/io/osc.lua
-- OSC in and feedback (S.lib.io_osc, 3.6 design §10). norns takes
-- /param/<id> <value> for every param by itself; this module's osc.event adds
-- six addresses for what is not a param (a scene, a voice's run and
-- retrigger, the patterns, a watch list and a hello) and remembers the last
-- sender. With the rig setting osc_feedback on and a sender known, one 15 Hz
-- clock sends watched values back to the sender's host at osc_port.
-- Notes: docs/notes/lua/io/osc.md

return function(S)
  local M = {}

  -- The tunables. watch is the starting watch list: the params of
  -- tools/touchosc/lib/layout.lua (the sixteen macros, each voice's mute and level)
  local OSC = {sends_per_tick = 32, feedback_hz = 15, echo_seconds = 0.25, watch = {}}
  M.OSC = OSC
  for m = 1, S.constants.NUM_MACROS do table.insert(OSC.watch, "macro_" .. m) end
  for voice = 1, S.constants.NUM_VOICES do
    table.insert(OSC.watch, "v" .. voice .. "_mute")
    table.insert(OSC.watch, "v" .. voice .. "_amp")
  end

  local NUM_VOICES = S.constants.NUM_VOICES
  local rig = S.lib.io_rig

  local state = {
    sender = nil,       -- the last sender's host
    watching = {},      -- the watch list, in order
    is_watched = {},    -- id -> true
    last_sent = {},     -- id -> the value the sender last has (sent, or arrived)
    arrived = {},       -- id -> util.time() of the last /param/<id> from OSC
    scene = nil,        -- the scene last sent
    running = {},       -- voice -> 0 or 1 last sent
    patterns = nil,     -- 0 or 1 last sent
    ticks = 0,          -- ticks run
    since = {},         -- id -> the tick it was first seen differing from last_sent
    clock = nil,        -- the feedback clock
    errors = {},        -- contained_call's last message per part
  }
  for _, id in ipairs(OSC.watch) do
    table.insert(state.watching, id)
    state.is_watched[id] = true
  end

  local function contained(key, label, fn, ...)
    return S.lib.ui_frame.contained_call(state.errors, key, label, fn, ...)
  end

  local function ignored(path, why)
    print("strata: osc " .. path .. " ignored: " .. why)
  end

  local function pattern_state() return S.pattern_playing and 1 or 0 end
  local function voice_state(voice) return S.voices[voice].active and 1 or 0 end

  -- What a sender is taken to know now: every watched value and the states
  local function baseline()
    for _, id in ipairs(state.watching) do state.last_sent[id] = params:get(id) end
    state.scene = S.current_scene
    for voice = 1, NUM_VOICES do state.running[voice] = voice_state(voice) end
    state.patterns = pattern_state()
  end

  -- Every watched value and the three states due at the next tick
  local function mark_all_due()
    state.last_sent = {}
    state.scene, state.running, state.patterns = nil, {}, nil
  end

  -- One tick: the states first (few), then watched params in list order that
  -- differ from what the sender has, at most sends_per_tick messages, each
  -- with the value now (so a value changed twice sends once)
  local function tick()
    local host = state.sender
    if not host then return end
    local to = {host, rig.get("osc_port")}
    local budget = OSC.sends_per_tick
    local function send(path, value)
      osc.send(to, path, {value})
      budget = budget - 1
    end
    if budget > 0 and S.current_scene ~= nil and S.current_scene ~= state.scene then
      state.scene = S.current_scene
      send("/strata/scene", state.scene)
    end
    for voice = 1, NUM_VOICES do
      local now = voice_state(voice)
      if budget > 0 and now ~= state.running[voice] then
        state.running[voice] = now
        send("/strata/voice/" .. voice .. "/running", now)
      end
    end
    if budget > 0 and pattern_state() ~= state.patterns then
      state.patterns = pattern_state()
      send("/strata/patterns", state.patterns)
    end
    -- The params that differ from what the sender has, the longest-waiting
    -- first (the tick it was first seen differing, then the list's order), so
    -- a param that changes every tick cannot shut out the ones after it. Each
    -- goes with its value now
    state.ticks = state.ticks + 1
    local now_time = util.time()
    local due = {}
    for index, id in ipairs(state.watching) do
      local arrived = state.arrived[id]
      if not (arrived and now_time - arrived < OSC.echo_seconds) then
        if params:get(id) ~= state.last_sent[id] then
          state.since[id] = state.since[id] or state.ticks
          due[#due + 1] = {id = id, since = state.since[id], index = index}
        else
          state.since[id] = nil
        end
      end
    end
    table.sort(due, function(a, b)
      if a.since ~= b.since then return a.since < b.since end
      return a.index < b.index
    end)
    for _, entry in ipairs(due) do
      if budget <= 0 then break end
      local value = params:get(entry.id)
      state.last_sent[entry.id] = value
      state.since[entry.id] = nil
      send("/param/" .. entry.id, value)
    end
  end

  local function stop_clock()
    if state.clock then
      clock.cancel(state.clock)
      state.clock = nil
    end
  end

  -- The clock runs only while feedback is on and a sender is known
  local function sync()
    local wanted = rig.get("osc_feedback") == "on" and state.sender ~= nil
    if wanted and not state.clock then
      baseline()
      state.clock = clock.run(function()
        while true do
          clock.sleep(1 / OSC.feedback_hz)
          contained("tick", "osc feedback", tick)
        end
      end)
    elseif not wanted then
      stop_clock()
    end
  end

  function M.running() return state.clock ~= nil end

  -- How many ids have an arrival time recorded (the tests' bound check)
  function M.tracked()
    local count = 0
    for _ in pairs(state.arrived) do count = count + 1 end
    return count
  end

  rig.on_change("osc_feedback", function() sync() end)

  -- A number argument, or nil after one console line
  local function number_arg(path, args)
    local value = args[1]
    if type(value) == "number" and value == value then return value end
    ignored(path, "the argument is " .. (value == nil and "missing" or "not a number"))
    return nil
  end

  local function watch(path, args)
    local id = args[1]
    if type(id) ~= "string" then return ignored(path, "the argument is not a param id") end
    if not params.lookup[id] then return ignored(path, "no param " .. id) end
    if state.is_watched[id] then return end
    state.is_watched[id] = true
    table.insert(state.watching, id)
    if state.clock then state.last_sent[id] = params:get(id) end
  end

  local VOICE_ACTIONS = {
    run = function(voice, value) S.lib.io_actions.run_voice(voice, value) end,
    retrigger = function(voice, value) S.lib.io_actions.retrigger(voice, value) end,
  }

  local function strata(path, args)
    if path == "/strata/scene" then
      local value = number_arg(path, args)
      if value then S.lib.io_actions.recall_scene(value) end
    elseif path == "/strata/patterns" then
      local value = number_arg(path, args)
      if value then S.lib.io_actions.patterns(value) end
    elseif path == "/strata/fill" then
      local value = number_arg(path, args)
      if value then S.lib.io_actions.fill(value) end
    elseif path == "/strata/watch" then
      watch(path, args)
    elseif path == "/strata/hello" then
      mark_all_due()
    else
      local voice, action = path:match("^/strata/voice/(%d+)/(%a+)$")
      if voice and VOICE_ACTIONS[action] then
        voice = tonumber(voice)
        if voice < 1 or voice > NUM_VOICES then
          return ignored(path, "voice " .. voice .. " is not 1 to " .. NUM_VOICES)
        end
        local value = number_arg(path, args)
        if value then VOICE_ACTIONS[action](voice, value) end
      else
        ignored(path, "no such address")
      end
    end
  end

  -- osc.event: norns runs its own /param handling after this returns
  -- (docs/design/3.6-facts/iii-osc-nb-softcut.md §2), so this never sets a param
  local function handle(path, args, from)
    if type(path) ~= "string" then return end
    if type(args) ~= "table" then args = {} end
    if type(from) == "table" and type(from[1]) == "string" then
      -- IO's osc title shows the sender, and the page does not animate
      if from[1] ~= state.sender then request_redraw() end
      state.sender = from[1]
      sync()
    end
    local id = path:match("^/param/([^/]+)$")
    if id then
      -- only a watched id is recorded: a sender cannot grow these tables
      if state.is_watched[id] then
        state.arrived[id] = util.time()
        if type(args[1]) == "number" then state.last_sent[id] = args[1] end
      end
    elseif path == "/strata" or path:sub(1, 8) == "/strata/" then
      strata(path, args)
    end
  end

  S.register_start(S.constants.START_ORDER.io_osc, function()
    osc.event = function(path, args, from) contained("event", "osc event", handle, path, args, from) end
    sync()
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.io_osc, function()
    stop_clock()
    state.sender = nil
    osc.event = nil
  end)

  S.register_io_section({
    name = "osc",
    title = "osc",
    rows = function()
      return {
        {label = "feedback", kind = "rig", key = "osc_feedback"},
        {label = "port", kind = "rig", key = "osc_port"},
      }
    end,
    status = function() return state.sender or "no sender" end,
    layout_states = {
      {name = "no sender", setup = function() state.sender = nil end},
      {name = "with a sender", setup = function() state.sender = "192.168.1.20" end},
    },
  })

  return M
end

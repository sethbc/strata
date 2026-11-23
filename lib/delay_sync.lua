-- lib/delay_sync.lua
-- The delay on the beat (3.7 design §6, decision 9; S.lib.delay_sync):
-- three params in the strata_fx group (delay_sync, delay_division,
-- delay_pingpong, through S.register_fx_params) and their scene fields;
-- M.time(), the time the delay's one engine sender (lib/engine_sync.lua)
-- plays: while synced the division at the tempo, halved until it is at most
-- DELAY.max_seconds (the engine's line), else the engine value of
-- delay_time (synced at a tempo that gives no length, delay_time with its
-- offsets now), so a synced delay ignores delay_time and its modulation;
-- M.playing() and M.label() for FX, the arc and the 256's fader; and the
-- LFO clock's step hook that resends the time when the tempo moves it
-- (through the round robin and the send budget). M.hold() holds a send
-- made while a scene applies, which the scene-applied hook sends once as
-- apply_entries ends; M.sent(time) notes a send's time, and
-- M.time_unheard() says a delay_time send would change nothing the engine
-- plays (the matrix skips it, #741).

return function(S)
  local M = {}
  local DIVISIONS = S.constants.DIVISIONS

  -- max_seconds: the engine's delay line (\strataDelay's buffer line and
  -- its clip on time, 5.4 s; a test compares them); default_division: 1/8D
  -- (an index of DIVISIONS.names); threshold: how far the synced time
  -- moves (a fraction of itself) from the time last sent before the step
  -- hook resends it
  M.DELAY = {max_seconds = 5.4, default_division = 7, threshold = 0.005}

  -- The send budget's id for the step hook's and a recall's sends: it holds
  -- a space, so no param id can be it. Its engine sender is the delay's
  local SEND_KEY = "delay sync"
  -- A halved length no division has, in seconds
  local SECONDS_FORMAT = "%.2f s"

  local function synced() return params:get("delay_sync") == 1 end

  -- While synced: the seconds the division plays at the tempo, halved until
  -- they fit, the division and the halvings; nil for a tempo that gives no
  -- finite length (an external clock reporting 0)
  local function synced_time()
    local division = params:get("delay_division")
    local beats = DIVISIONS.beats[division]
    local seconds = beats and beats * S.lib.params_setup.beat_seconds_now()
    if seconds == nil or seconds ~= seconds or seconds <= 0 or seconds == math.huge then return nil end
    local halvings = 0
    while seconds > M.DELAY.max_seconds do
      seconds = seconds / 2
      halvings = halvings + 1
    end
    return seconds, division, halvings
  end

  -- The mode (3.9, #911): "free" (sync off), "division" (synced at a tempo
  -- that gives a length, then synced_time's seconds, division and
  -- halvings) or "synced, no length" (synced at a tempo that gives none)
  local function mode()
    if not synced() then return "free" end
    local seconds, division, halvings = synced_time()
    if seconds then return "division", seconds, division, halvings end
    return "synced, no length"
  end

  -- The time (s) the delay plays: the synced division's; unsynced,
  -- delay_time as the engine has it (its LFO and matrix offsets included);
  -- synced at a tempo that gives no length, delay_time with its offsets as
  -- they are now, since the modulation's sends were skipped while synced
  -- and the value delivered may be stale (#768)
  function M.time()
    local current, seconds = mode()
    if current == "free" then return engine_param_value("delay_time") end
    if current == "division" then return seconds end
    return S.lib.engine_sync.with_lfo_offsets("delay_time", params:get("delay_time"))
  end

  -- {division = index into DIVISIONS, halvings = n} while synced, else nil
  function M.playing()
    if not synced() then return nil end
    local seconds, division, halvings = synced_time()
    if not seconds then return nil end
    return {division = division, halvings = halvings}
  end

  local function division_named(beats)
    for index, each in ipairs(DIVISIONS.beats) do
      if math.abs(each - beats) < 1e-9 then return DIVISIONS.names[index] end
    end
  end

  -- What FX's time row shows while synced: the division ("1/8D"), or while
  -- halved the division and what plays ("1 bar>1/2": the division whose
  -- beats equal the halved length, or its seconds when none does); nil
  -- while not synced
  function M.label()
    local playing = M.playing()
    if not playing then return nil end
    local name = DIVISIONS.names[playing.division]
    if playing.halvings == 0 then return name end
    local halved = division_named(DIVISIONS.beats[playing.division] / 2 ^ playing.halvings)
    return name .. ">" .. (halved or string.format(SECONDS_FORMAT, M.time()))
  end

  -- The time the delay's sender last sent (nil: none yet, so the engine
  -- plays its default, delay_time's), and the feedback, mix and ping-pong
  -- that send carried (their engine values as it went)
  local last_sent
  local OTHERS = {"delay_feedback", "delay_mix", "delay_pingpong"}
  local last_others = {}
  function M.sent(time)
    last_sent = time
    for _, param_id in ipairs(OTHERS) do last_others[param_id] = engine_param_value(param_id) end
  end

  -- Whether a send of delay_time would change nothing the engine plays
  -- (#741): synced at a finite division, after a first send, with the
  -- feedback, mix and ping-pong the engine has those that send carried. A
  -- synced time that moved is the step hook's to resend, so this holds
  -- whatever the time last sent (#768: a tempo move sends once). The
  -- matrix and the macros mark delay_time due only while this is false, so
  -- a synced delay under an LFO or a routing on delay_time sends nothing
  -- and takes no slot of the round robin
  function M.time_unheard()
    if mode() ~= "division" or last_sent == nil then return false end
    for _, param_id in ipairs(OTHERS) do
      if last_others[param_id] ~= engine_param_value(param_id) then return false end
    end
    return true
  end

  S.engine_senders[SEND_KEY] = function() S.engine_senders.delay_time() end
  local function send_due() S.lib.engine_sync.send_engine_value(SEND_KEY, M.time()) end

  -- Mark the delay's sender due: the next LFO step sends setDelay once, with
  -- every value as it is then (the step hook's resend)
  function M.resend() S.lib.lfos.mark_due(SEND_KEY, send_due) end

  -- A send made while a scene applies (lib/engine_sync.lua's sender) is
  -- held; as apply_entries ends (an instant recall, a fade's landing, morph's
  -- discrete entries) the hook sends setDelay once with every value the
  -- scene set, through send_engine_value: a recall's at once, never
  -- deferred; a morph's inside morph's deferrable, so it waits as every
  -- morph write does when the window is full
  local held = false
  function M.hold() held = true end
  -- Whether a send is held now (true only inside a scene's apply)
  function M.held() return held end
  S.register_scene_applied({name = "delay sync", fn = function()
    if not held then return end
    held = false
    send_due()
  end})

  -- Synced at a tempo that gives no length the delay plays delay_time with
  -- its offsets, which the matrix and the macros mark due under delay_time's
  -- own key (time_unheard is false there) before this hook runs: the
  -- resend goes under that key too, so a step the modulation also marked
  -- sends one setDelay (#770), and a step it did not (no modulation, the
  -- step the tempo stops giving a length) still sends the time
  local function send_time() S.lib.engine_sync.send_engine_value("delay_time", M.time()) end

  -- Every LFO step: a time that moved by more than threshold of itself from
  -- the one last sent (a tempo change under sync) is sent in this step
  S.lib.lfos.on_step(function()
    local time = M.time()
    local sent = last_sent or param_default("delay_time")
    if math.abs(time - sent) <= M.DELAY.threshold * time then return end
    if mode() == "synced, no length" then
      S.lib.lfos.mark_due("delay_time", send_time)
    else
      M.resend()
    end
  end)

  -- 3.9 (#911): a held send only inside a scene's apply (the scene-applied
  -- hook flushes it as apply_entries ends); with sync off, once a send has
  -- gone, the time last sent is the time the delay plays (every change of
  -- it sends at once). A synced time is not checked: a tempo moves with no
  -- event this module sees, and the next step catches up
  S.register_invariant("delay sync", function()
    if held and not S.scene_recall_in_progress then return "a send is held with no scene applying" end
    if mode() == "free" and last_sent ~= nil and last_sent ~= M.time() then
      return "unsynced, the time last sent is " .. tostring(last_sent) .. ", the delay plays " .. tostring(M.time())
    end
  end)

  -- sync and the division change what FX's time row, arc ring 3 and the
  -- 256's delay fader show (a scene that sets them, S.lib.scenes.setting(),
  -- redraws the grid once itself, #867)
  local function shown_changed()
    if S.lib.grid_core.any_fx_faders() and not S.lib.scenes.setting() then grid_redraw() end
    request_redraw()
  end

  S.register_fx_params({
    name = "delay sync",
    count = 3,
    add = function()
      params:add{type = "binary", id = "delay_sync", name = "delay sync", behavior = "toggle", default = 0,
        action = function(x)
          -- turning sync off sends delay_time with its offsets as they are
          -- now: a synced delay's modulation sends were skipped (#741), so
          -- the value last delivered may be stale
          if x == 1 then
            send_param_to_engine("delay_sync", x)
          else
            send_param_to_engine("delay_time", params:get("delay_time"))
          end
          shown_changed()
        end}
      params:add{type = "option", id = "delay_division", name = "delay division", options = DIVISIONS.names,
        default = M.DELAY.default_division,
        action = function(x)
          send_param_to_engine("delay_division", x)
          shown_changed()
        end}
      params:add{type = "control", id = "delay_pingpong", name = "delay ping-pong",
        controlspec = controlspec.new(0, 1, "lin", 0.01, 0),
        action = function(x) send_param_to_engine("delay_pingpong", x) end}
      for _, param_id in ipairs({"delay_sync", "delay_division", "delay_pingpong"}) do
        S.engine_senders[param_id] = function() S.engine_senders.delay_time() end
      end
    end,
  })

  -- Scenes: sync and the division switch at a fade's end, ping-pong
  -- crossfades
  S.register_scene_field({id = "delay_sync", default = 0, discrete = true})
  S.register_scene_field({id = "delay_division", default = M.DELAY.default_division, discrete = true})
  S.register_scene_field({id = "delay_pingpong", default = 0})

  return M
end

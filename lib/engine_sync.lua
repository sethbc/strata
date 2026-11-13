-- lib/engine_sync.lua
-- Param -> engine: send_param_to_engine and the engine senders
-- (S.engine_senders), the values the engine last got (S.engine_param_values),
-- the LFO offsets they add (S.lfo_last_dest, S.lfo_scaled), and starting,
-- stopping, locking and syncing a voice (the registered voice params'
-- grain keys and syncs included). The functions that were global stay
-- global, as does engine_param_value; engine_mod_source, with_lfo_offsets,
-- send_engine_value and grain_key_message are fields of this module's table
-- (S.lib.engine_sync) for the code that calls them: engine_mod_source and
-- grain_key_message in lib/params_setup.lua, the other two in lib/lfos.lua
-- (the LFO clock); start_voice for the pattern clock (lib/sequencer.lua);
-- add_voice_sender for lib/params_setup.lua's voice params, whose sends
-- to a stopped voice the send budget leaves uncounted (#642).
-- 3.4's hooks are fields too: the base override (set_base_override,
-- clear_base_override, engine_base_value), extra offsets
-- (set_extra_offset) and the send budget (deferrable, budget_state;
-- S.deferrable_write, S.engine_budget_clock). 3.5's: count_sends (direct
-- sends counted in the budget's window) and the voice-stop hooks
-- (S.registry.voice_stop) after every voiceOff. Registers the cleanup step
-- that sends a voiceOff for every running voice (norns has freed the
-- engine by then, so none arrives: the voices stopped with it) and the
-- budget's.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
  local NUM_LFOS = S.constants.NUM_LFOS

  -- Convert a Lua mod source (0 = none, 1..NUM_VOICES = voice number) to the
  -- engine's 0-indexed form (-1 = none, 0..NUM_VOICES-1 = voice index)
  local function engine_mod_source(source)
    if source == 0 then return -1 end
    return source - 1
  end

  -- Param -> engine. A param action stores its value and calls
  -- send_param_to_engine(id, value), which adds the offsets of any global LFO
  -- modulating that param, so an edit (or the drift, a mutation, a scene fade)
  -- never sends the plain value under a running LFO. The LFOs drive the
  -- engine through the same path (send_engine_value). engine_senders[id]
  -- holds the engine call for a param (gated on the voice running where the
  -- engine needs that). engine_param_values remembers the last value sent per
  -- param, so a command that carries several params (setFilter, setDelay,
  -- setReverb, grain density x master density) sends the others as the engine
  -- has them: an LFO on filter res and one on filter freq do not undo each
  -- other.
  S.engine_senders = {}
  S.engine_param_values = {}
  S.lfo_last_dest = {}   -- per LFO: param id it modulates now (nil = none)
  S.lfo_scaled = {}      -- per LFO: its last scaled value (-depth..depth) at S.lfo_last_dest

  -- The value the engine last got for a param (its stored value until sent)
  function engine_param_value(param_id)
    local value = S.engine_param_values[param_id]
    if value == nil then return params:get(param_id) end
    return value
  end

  -- 3.4's modulation state (design §0.1), local to this module and reached
  -- through the functions below: per param id, the base override a step
  -- lock or note holds (the sequencer's; nil: the stored value), and the
  -- extra offsets, per param id {source_key = offset in the param's units}
  local base_overrides = {}
  local extra_offsets = {}

  -- value plus scaled * half the range of every LFO on param_id (LFOs on one
  -- destination add up) and every extra offset on it, clamped once to the
  -- range; value itself when nothing modulates it. A base override set on
  -- the param takes value's place (a step lock holds the engine there)
  local function with_lfo_offsets(param_id, value)
    local override = base_overrides[param_id]
    if override ~= nil then value = override end
    local offset, modulated = 0, false
    for n = 1, NUM_LFOS do
      if S.lfo_last_dest[n] == param_id then
        offset = offset + S.lfo_scaled[n]
        modulated = true
      end
    end
    local minval, maxval
    local extras = extra_offsets[param_id]
    if modulated then
      minval, maxval = param_range(param_id)
      offset = offset * 0.5 * (maxval - minval)
    end
    if extras then
      for _, extra in pairs(extras) do offset = offset + extra end
      if not modulated then minval, maxval = param_range(param_id) end
      modulated = true
    end
    if not modulated then return value end
    return util.clamp(value + offset, minval, maxval)
  end

  -- A voice param's engine sender (lib/params_setup.lua's synthesis, grain,
  -- buffer and crossmod params and the registered grain keys): its call
  -- runs only while the voice runs (a start sends everything:
  -- M.start_voice). voice_gates keeps, per param id, the voice and the
  -- gated sender, so the send budget can ask whether a send reaches the
  -- engine before it counts it (#642). A sender installed over it later
  -- (another S.engine_senders entry) is no longer gated
  local voice_gates = {}

  function M.add_voice_sender(voice_idx, param_id, send)
    local function sender(value)
      if S.voices[voice_idx].active then send(value) end
    end
    S.engine_senders[param_id] = sender
    voice_gates[param_id] = {voice = voice_idx, sender = sender}
  end

  -- The master density's sender (below): one grainDensity per running voice
  local send_master_density_to_engine

  -- How many engine messages a send of the id makes now (what the budget
  -- counts): 0 for an id with no sender (#646) and for a stopped voice's
  -- param, whose gated sender sends nothing; one per running voice for the
  -- master density (#645); else 1
  local function engine_messages(param_id)
    local sender = S.engine_senders[param_id]
    if sender == nil then return 0 end
    local gate = voice_gates[param_id]
    if gate ~= nil and sender == gate.sender then return S.voices[gate.voice].active and 1 or 0 end
    if sender == send_master_density_to_engine then
      local running = 0
      for i = 1, NUM_VOICES do
        if S.voices[i].active then running = running + 1 end
      end
      return running
    end
    return 1
  end

  -- Whether a send of the id reaches the engine now
  local function reaches_engine(param_id)
    return engine_messages(param_id) > 0
  end

  -- The send budget (Question 23): every send_engine_value counts the
  -- engine messages it makes (engine_messages) against the current window,
  -- math.floor(util.time() / window_seconds), which never goes back. A
  -- send made while S.deferrable_write is set (the Lua LFOs, morph, gesture
  -- playback, the macros: deferrable(fn)) whose messages the window has no
  -- room left for (messages_per_window) waits as its id's
  -- pending value, the newest winning, and goes first in the next window,
  -- in the order the ids first waited: from S.engine_budget_clock, which
  -- runs only while something waits, or from the first send of that
  -- window, whichever comes first. Every other send goes at once and drops
  -- its id's pending value. A send that reaches no engine (a stopped
  -- voice's param, reaches_engine) never counts and never waits: its value
  -- is recorded at once, as one that reaches the engine would be (#642)
  local ENGINE_BUDGET = S.constants.ENGINE_BUDGET
  S.deferrable_write = false
  S.engine_budget_clock = nil
  -- failed: the ids whose sender raised on a waiting value (reported once)
  local budget = {window = -math.huge, sent = 0, pending = {}, order = {}, failed = {}}

  -- Record the value as sent, and when it reaches the engine count its
  -- messages and run the param's engine call (none when the value already
  -- went in a start's own messages)
  local function deliver(param_id, value, already_sent)
    local messages = engine_messages(param_id)
    if messages == 0 then
      S.engine_param_values[param_id] = value
      return
    end
    budget.sent = budget.sent + messages
    S.engine_param_values[param_id] = value
    local sender = S.engine_senders[param_id]
    if sender and not already_sent then sender(value) end
  end

  local function drop_pending(param_id)
    if budget.pending[param_id] == nil then return end
    budget.pending[param_id] = nil
    for index, waiting in ipairs(budget.order) do
      if waiting == param_id then table.remove(budget.order, index); break end
    end
  end

  -- Whether the window has room for a send of messages more. An empty
  -- window takes any send, so one larger than a whole window costs that
  -- window and never blocks the flush
  local function window_has_room(messages)
    return budget.sent == 0 or budget.sent + messages <= ENGINE_BUDGET.messages_per_window
  end

  -- The waiting values, oldest first, as far as the window's budget goes
  -- (one whose messages do not fit stops the flush: the order is kept).
  -- Each goes on its own: a sender that raises is reported once per param
  -- ("strata: engine send <id> failed: <error>") and the rest still go, so
  -- the flush clock never dies with values waiting and the send that
  -- opened the window never carries another param's error (#637)
  local function flush_pending()
    while #budget.order > 0 and window_has_room(engine_messages(budget.order[1])) do
      local param_id = table.remove(budget.order, 1)
      local value = budget.pending[param_id]
      budget.pending[param_id] = nil
      local sent, failure = xpcall(function() deliver(param_id, value) end, with_traceback)
      if not sent and not budget.failed[param_id] then
        budget.failed[param_id] = true
        print("strata: engine send " .. param_id .. " failed: " .. tostring(failure))
      end
    end
  end

  -- Move to window (never back): a new window's count starts at 0 and its
  -- first sends are the waiting values
  local function enter_window(window)
    if window <= budget.window then return end
    budget.window = window
    budget.sent = 0
    flush_pending()
  end

  local function current_window()
    return math.floor(util.time() / ENGINE_BUDGET.window_seconds)
  end

  -- Start the flush clock if it is not running: it sleeps to the next
  -- window's start, enters it and sends what waits, until nothing does.
  -- It is never canceled while the script runs (#654): matron may have
  -- posted its resume when a send empties the waiting list (another clock
  -- of its tick, delivered first), and norns' clock.resume raises on a
  -- canceled coroutine. So it ends at its own wake, once it finds nothing
  -- waiting; a value that waits meanwhile is this clock's, sent at that
  -- wake, the next window's start (never a second clock)
  local function start_budget_clock()
    if S.engine_budget_clock then return end
    S.engine_budget_clock = clock.run(function()
      while #budget.order > 0 do
        local next_window = math.max(current_window(), budget.window) + 1
        clock.sleep(math.max(0, next_window * ENGINE_BUDGET.window_seconds - util.time()))
        enter_window(math.max(current_window(), next_window))
      end
      S.engine_budget_clock = nil
    end)
  end

  -- Send now, whatever S.deferrable_write says: counted, dropping the id's
  -- pending value (older than this one)
  local function send_now(param_id, value, already_sent)
    enter_window(current_window())
    drop_pending(param_id)
    deliver(param_id, value, already_sent)
  end

  -- Send a param's value to the engine (one path for every value), within
  -- the budget (a send that reaches no engine goes at once, uncounted)
  local function send_engine_value(param_id, value)
    local messages = S.deferrable_write and engine_messages(param_id) or 0
    if messages > 0 then
      enter_window(current_window())
      if not window_has_room(messages) then
        if budget.pending[param_id] == nil then table.insert(budget.order, param_id) end
        budget.pending[param_id] = value
        start_budget_clock()
        return
      end
    end
    send_now(param_id, value)
  end

  -- Run fn with S.deferrable_write set: its sends may wait for the next
  -- window. The flag comes back as it was, even when fn raises (the error
  -- is raised again, with its traceback). fn never yields (no clock.sleep
  -- or clock.sync inside it): the flag would stay set across the wait, and
  -- a hand edit made meanwhile would be deferred. A caller that waits
  -- sleeps outside deferrable and wraps each burst of writes
  function M.deferrable(fn)
    local outer = S.deferrable_write
    S.deferrable_write = true
    local ran, run_error = xpcall(fn, with_traceback)
    S.deferrable_write = outer
    if not ran then error(run_error, 0) end
  end

  -- The value the engine has or will have for the id: the one waiting in
  -- the budget when there is one, else the one it last received (nil when
  -- neither). A compare that decides whether to send reads this, never
  -- S.engine_param_values alone (#591)
  function M.expected_value(param_id)
    local waiting = budget.pending[param_id]
    if waiting ~= nil then return waiting end
    return S.engine_param_values[param_id]
  end

  -- Count n engine messages (a whole number, at least 0) a module sent
  -- itself, outside send_engine_value (3.5's notes, design §6.4), in the
  -- current window, as deliver counts a send (a new window first, with its
  -- waiting values). Defers nothing and sends nothing: the deferrable sends
  -- make room. Anything else raises
  function M.count_sends(n)
    if type(n) ~= "number" or n ~= n or n < 0 or n == math.huge or n % 1 ~= 0 then
      error("count_sends: a whole number of messages, at least 0, not " .. tostring(n), 2)
    end
    if n == 0 then return end
    enter_window(current_window())
    budget.sent = budget.sent + n
  end

  -- For tests: this window's sends and the ids waiting
  function M.budget_state()
    local sent = budget.sent
    if current_window() > budget.window then sent = 0 end
    return {sent = sent, pending = #budget.order}
  end

  -- A value waits only while the flush clock runs (it may run on with
  -- nothing waiting, to its next wake, where it ends), the clock is a live
  -- coroutine, and every waiting id has a value (#654)
  S.register_invariant("engine budget", function()
    if #budget.order > 0 and S.engine_budget_clock == nil then
      return #budget.order .. " values wait but no flush clock runs"
    end
    local thread = S.engine_budget_clock and clock.threads and clock.threads[S.engine_budget_clock]
    if S.engine_budget_clock and type(thread) == "thread" and coroutine.status(thread) == "dead" then
      return "the flush clock " .. tostring(S.engine_budget_clock) .. " has ended"
    end
    for _, param_id in ipairs(budget.order) do
      if budget.pending[param_id] == nil then return param_id .. " waits with no value" end
    end
  end)

  -- Cancel the flush clock; what waits is never sent (norns has freed the
  -- engine by then, #461)
  S.register_cleanup(S.constants.CLEANUP_ORDER.engine_budget, function()
    budget.pending, budget.order = {}, {}
    if S.engine_budget_clock then
      clock.cancel(S.engine_budget_clock)
      S.engine_budget_clock = nil
    end
  end)

  -- A param's stored value, as modulated by the LFOs on it. Always sends.
  function send_param_to_engine(param_id, value)
    send_engine_value(param_id, with_lfo_offsets(param_id, value))
  end

  -- The base override (the sequencer's step locks and notes, its one user;
  -- an LFO on a macro moves extra offsets instead): while one is set the
  -- engine starts from it instead of the stored value, which keeps
  -- changing underneath (a param action's send is held under it). Setting
  -- and clearing send at once. Only a hand edit of the param clears it (the
  -- touch hook below), never the drift, morph, a macro or gesture playback
  local function send_base(param_id)
    send_engine_value(param_id, with_lfo_offsets(param_id, params:get(param_id)))
  end

  -- The value is a finite number: anything else raises, naming the param
  -- (a caller clears with clear_base_override)
  function M.set_base_override(param_id, value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
      error("set_base_override: " .. tostring(param_id) .. "'s override is a finite number, not " .. tostring(value), 2)
    end
    base_overrides[param_id] = value
    send_base(param_id)
  end

  function M.clear_base_override(param_id)
    if base_overrides[param_id] == nil then return end
    base_overrides[param_id] = nil
    send_base(param_id)
  end

  -- The value the engine starts from: the override, else the stored value
  function M.engine_base_value(param_id)
    local override = base_overrides[param_id]
    if override ~= nil then return override end
    return params:get(param_id)
  end

  S.register_param_touch(function(param_id) M.clear_base_override(param_id) end)

  -- An extra offset on a Lua destination, in the param's units (nil
  -- clears): summed with the LFOs' in with_lfo_offsets and clamped once
  -- with them. Sends nothing: the source sends the param when it moves
  function M.set_extra_offset(source_key, param_id, offset)
    local extras = extra_offsets[param_id]
    if offset == nil then
      if extras then
        extras[source_key] = nil
        if next(extras) == nil then extra_offsets[param_id] = nil end
      end
      return
    end
    if not extras then
      extras = {}
      extra_offsets[param_id] = extras
    end
    extras[source_key] = offset
  end

  -- sync_voice_values_to_engine sends a voice's stored values: forget what
  -- was sent for its params before, and every value of theirs still
  -- waiting for the budget (older than what the sync sends)
  local function forget_sent_voice_values(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    for param_id in pairs(S.engine_param_values) do
      if param_id:sub(1, #prefix) == prefix then
        S.engine_param_values[param_id] = nil
      end
    end
    for index = #budget.order, 1, -1 do
      local param_id = budget.order[index]
      if param_id:sub(1, #prefix) == prefix then drop_pending(param_id) end
    end
  end

  -- A start's value for a param (#632): while a base override or an extra
  -- offset is held on it, the value with them (with_lfo_offsets), so the
  -- start's first value is the one the engine should play; else the stored
  -- value, as before 3.4. carried notes each modulated value sent, so the
  -- start's resend only records it
  local function start_value(carried, param_id, value)
    if base_overrides[param_id] == nil and extra_offsets[param_id] == nil then return value end
    value = with_lfo_offsets(param_id, value)
    carried[param_id] = value
    return value
  end

  -- The end of a voice's sync and start: a sync's own sends carry the
  -- stored values, so every param of the voice that holds a base override
  -- or an extra offset is sent again with them (with_lfo_offsets), at once
  -- (never deferred), in id order. A start's own sends already carried
  -- them (carried: start_value's), which are only recorded as sent, so
  -- nothing it sent before voiceOn follows it again. Sends nothing while
  -- none is held
  local function resend_modulated_voice_params(voice_idx, carried)
    local prefix = "v" .. voice_idx .. "_"
    local ids, listed = {}, {}
    for _, held in ipairs({base_overrides, extra_offsets}) do
      for param_id in pairs(held) do
        if param_id:sub(1, #prefix) == prefix and not listed[param_id] then
          listed[param_id] = true
          ids[#ids + 1] = param_id
        end
      end
    end
    table.sort(ids)
    for _, param_id in ipairs(ids) do
      local value = with_lfo_offsets(param_id, params:get(param_id))
      send_now(param_id, value, carried ~= nil and carried[param_id] == value)
    end
  end

  -- Effects chain (filter -> delay -> reverb -> master). Each filter, delay or
  -- reverb param sends its whole command, with the values the engine has for
  -- the others.
  local function send_filter_to_engine()
    engine.setFilter(engine_param_value("filter_freq"), engine_param_value("filter_res"),
      engine_param_value("filter_type") - 1, engine_param_value("filter_mix"))
  end

  local function send_delay_to_engine()
    engine.setDelay(engine_param_value("delay_time"), engine_param_value("delay_feedback"),
      engine_param_value("delay_mix"))
  end

  local function send_reverb_to_engine()
    engine.setReverb(engine_param_value("reverb_mix"), engine_param_value("reverb_size"),
      engine_param_value("reverb_damp"))
  end

  -- Master density scales every running voice's grain density: one
  -- message per running voice, as the budget counts it (engine_messages,
  -- which declares this local)
  function send_master_density_to_engine(density)
    for i = 1, NUM_VOICES do
      if S.voices[i].active then
        engine.setGrainParam(i - 1, "grainDensity", engine_param_value("v" .. i .. "_grain_density") * density)
      end
    end
  end

  S.engine_senders.master_density = send_master_density_to_engine
  S.engine_senders.filter_type = send_filter_to_engine
  S.engine_senders.filter_freq = send_filter_to_engine
  S.engine_senders.filter_res = send_filter_to_engine
  S.engine_senders.filter_mix = send_filter_to_engine
  S.engine_senders.delay_time = send_delay_to_engine
  S.engine_senders.delay_feedback = send_delay_to_engine
  S.engine_senders.delay_mix = send_delay_to_engine
  S.engine_senders.reverb_mix = send_reverb_to_engine
  S.engine_senders.reverb_size = send_reverb_to_engine
  S.engine_senders.reverb_damp = send_reverb_to_engine
  S.engine_senders.drift_amount = function(value) engine.setMasterDrift(value) end

  -- The source each voice's engine has (what engine.setGrainSource last
  -- sent), per voice. A running voice whose source changes gets a new
  -- grain synth, so the grain-restart hooks run (S.registry.grain_restart)
  -- (lives in this load's constructor, on the fresh S: a script reload resets it)
  local sent_sources = {}

  local function run_grain_restart_hooks(voice_idx)
    for _, hook in ipairs(S.registry.grain_restart) do hook(voice_idx) end
  end

  -- Every engine.setGrainSource goes through here, so the remembered source
  -- stays true. The same source again, or a stopped voice's change, runs no
  -- hook (a stopped voice has no grain synth; voiceOn builds the right one)
  function M.send_grain_source(voice_idx)
    local source = S.voices[voice_idx].source
    engine.setGrainSource(voice_idx - 1, source - 1)
    local changed = sent_sources[voice_idx] ~= source
    sent_sources[voice_idx] = source
    if changed and S.voices[voice_idx].active then run_grain_restart_hooks(voice_idx) end
  end

  -- The voice-stop hooks (S.registry.voice_stop, 3.5), run after each
  -- engine.voiceOff the script sends, with the voice. Each is protected,
  -- as the LFO step hooks are: one that raises is printed with its
  -- traceback once per distinct message per hook (contained_call) and the
  -- next still runs, so no hook breaks a stop (its redraws, a failed
  -- start's own error, the other voices' voiceOffs and later cleanup steps)
  local voice_stop_errors = {}
  local function run_voice_stop_hooks(voice_idx)
    for index, hook in ipairs(S.registry.voice_stop) do
      S.lib.ui_frame.contained_call(voice_stop_errors, index, "voice stop hook", hook, voice_idx)
    end
  end

  function toggle_voice(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local voice = S.voices[voice_idx]
    
    if voice.active then
      engine.voiceOff(voice_idx - 1)
      voice.active = false
      run_voice_stop_hooks(voice_idx)
    else
      M.start_voice(voice_idx)
    end

    update_voice_list()
    request_redraw()
    grid_redraw()
  end

  -- Flip a voice's lock, then run the lock hooks (S.registry.lock_change)
  -- with the voice and its new state
  function toggle_lock(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    S.frozen[voice_idx] = not S.frozen[voice_idx]
    for _, hook in ipairs(S.registry.lock_change) do hook(voice_idx, S.frozen[voice_idx]) end
    update_voice_list()
    request_redraw()
    grid_redraw()
  end

  -- A registered record's grain key (S.registry.voice_params' grain_keys:
  -- an engine name, or {name, value = fn}) and a stored value: the
  -- setGrainParam name and the value to send
  local function grain_key_message(grain_key, value)
    if type(grain_key) == "table" then
      return grain_key.name, grain_key.value and grain_key.value(value) or value
    end
    return grain_key, value
  end

  -- A part's value for a voice param: the stored value for a sync (carried
  -- nil), a start's value (start_value) for a start
  local function part_value(carried, voice_idx, key, value)
    if not carried then return value end
    return start_value(carried, "v" .. voice_idx .. "_" .. key, value)
  end

  -- The registered voice params' part of the sync (S.registry.voice_params):
  -- per record, in registration order, its grain keys' stored values (by key
  -- name, so the order is fixed; a start's carry their overrides and
  -- offsets), then its sync
  local function send_registered_voice_values(voice_idx, carried)
    local voice = S.voices[voice_idx]
    for _, record in ipairs(S.registry.voice_params) do
      local keys = {}
      for key in pairs(record.grain_keys or {}) do table.insert(keys, key) end
      table.sort(keys)
      for _, key in ipairs(keys) do
        local name, value = grain_key_message(record.grain_keys[key],
          part_value(carried, voice_idx, key, voice.extras[key]))
        engine.setGrainParam(voice_idx - 1, name, value)
      end
      if record.sync then record.sync(voice_idx) end
    end
  end

  -- The parts of a voice's state, as the engine takes them. The grain params
  -- (the buffer params included) and the registered voice params
  -- (send_registered_voice_values) are setGrainParam messages, which the
  -- engine keeps for a stopped voice too: a start sends them before voiceOn
  -- (M.start_voice). The synth params, crossmod and bend are voice-level
  -- controls, which voiceOn resets: a start sends them after it. carried:
  -- a start's (start_value), nil for a sync's stored values
  local function send_grain_params(voice_idx, carried)
    local voice = S.voices[voice_idx]
    local engine_voice = voice_idx - 1
    local function value(key, stored) return part_value(carried, voice_idx, key, stored) end
    engine.setGrainParam(engine_voice, "grainSize", value("grain_size", voice.grain.size))
    engine.setGrainParam(engine_voice, "grainDensity",
      value("grain_density", voice.grain.density) * engine_param_value("master_density"))
    engine.setGrainParam(engine_voice, "pitchShift", value("grain_pitch", voice.grain.pitch))
    engine.setGrainParam(engine_voice, "posSpread", value("grain_spread", voice.grain.spread))
    engine.setGrainParam(engine_voice, "envShape", voice.grain.env - 1)
    engine.setGrainParam(engine_voice, "grainMode", voice.grain.mode - 1)
    engine.setGrainParam(engine_voice, "bufPos", value("buf_pos", voice.grain.buf_pos))
    engine.setGrainParam(engine_voice, "bufRate", value("buf_rate", voice.grain.buf_rate))
    engine.setGrainParam(engine_voice, "bufScan", value("buf_scan", voice.grain.buf_scan))
  end

  local function send_synth_params(voice_idx, carried)
    for key, value in pairs(S.voices[voice_idx].params) do
      engine.setVoiceParam(voice_idx - 1, key, part_value(carried, voice_idx, key, value))
    end
  end

  local function send_crossmod_and_bend(voice_idx)
    local voice = S.voices[voice_idx]
    local engine_voice = voice_idx - 1
    for slot = 1, NUM_MOD_SLOTS do
      local slot_state = voice.crossmod["slot" .. slot]
      engine.setModSource(engine_voice, slot, engine_mod_source(slot_state.source))
      engine.setModAmpAmt(engine_voice, slot, slot_state.amp_amt)
      engine.setModFreqAmt(engine_voice, slot, slot_state.freq_amt)
    end
    engine.setModSpeed(engine_voice, voice.crossmod.speed)
    -- the MIDI pitchbend wheel's current position (voiceOn resets the engine's to 1)
    engine.setVoiceParam(engine_voice, "bend", S.midi_state.bend[voice_idx])
  end

  -- A running voice's whole state after its source (a source switch, which
  -- sends the source itself, and a scene recall): synthesis, grain
  -- (including the buffer params) and crossmod values, then the registered
  -- voice params. A start sends the same messages in its own order
  -- (M.start_voice)
  function sync_voice_values_to_engine(voice_idx)
    -- the engine now gets this voice's stored values (LFOs re-apply theirs
    -- on their next step)
    forget_sent_voice_values(voice_idx)
    send_synth_params(voice_idx)
    send_grain_params(voice_idx)
    send_crossmod_and_bend(voice_idx)
    send_registered_voice_values(voice_idx)
    resend_modulated_voice_params(voice_idx)
  end

  -- Start a stopped voice and mark it running, redrawing nothing:
  -- toggle_voice redraws after it, and a pattern step once for all the
  -- voices it starts (#527). A voice outside 1..NUM_VOICES, or one already
  -- running, is left alone.
  -- The source and every grain value go first: the engine keeps a stopped
  -- voice's and builds or re-gates its grain synth with them inside voiceOn's
  -- own bundle, so the first grain plays this start's values, never the last
  -- run's (#325). Every value a start sends carries the param's base
  -- override and extra offsets (start_value: a step's locks and note, set
  -- before the start, #632), so the first grain plays them too. voiceOn
  -- carries the values just sent, and the voice-level values follow it.
  -- The grain-restart hooks run after voiceOn, before the voice is marked
  -- running (lib/midi_in.lua's relies on it). A send that raises before
  -- voiceOn has started nothing; once voiceOn is sent, a hook or a send
  -- that raises sends voiceOff and raises the error again, so the engine
  -- and voice.active always agree (#382)
  function M.start_voice(voice_idx)
    if type(voice_idx) ~= "number" or voice_idx % 1 ~= 0 or voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local voice = S.voices[voice_idx]
    if voice.active then return end
    local carried = {}  -- param id -> the modulated value the start sent (start_value)
    local function value(key, stored) return part_value(carried, voice_idx, key, stored) end
    forget_sent_voice_values(voice_idx)
    -- not running yet, so no restart hook runs here
    M.send_grain_source(voice_idx)
    send_grain_params(voice_idx, carried)
    send_registered_voice_values(voice_idx, carried)
    engine.voiceOn(voice_idx - 1, value("freq", voice.params.freq), value("amp", voice.params.amp),
      value("pan", voice.params.pan or 0), value("grain_size", voice.grain.size),
      value("grain_density", voice.grain.density) * engine_param_value("master_density"),
      value("grain_pitch", voice.grain.pitch))
    local started, start_error = xpcall(function()
      -- voiceOn built the synths for the source the engine has recorded
      run_grain_restart_hooks(voice_idx)
      send_synth_params(voice_idx, carried)
      send_crossmod_and_bend(voice_idx)
    end, with_traceback)
    if not started then
      engine.voiceOff(voice_idx - 1)
      run_voice_stop_hooks(voice_idx)
      -- level 0: the message already carries its traceback
      error(start_error, 0)
    end
    voice.active = true
    -- the overridden and offset params: recorded as sent (the start carried
    -- them), or sent last when a hook changed one meanwhile
    resend_modulated_voice_params(voice_idx, carried)
  end

  -- A voiceOff for every running voice (after MIDI is detached, so no note
  -- can start one again). norns frees the engine before it calls cleanup()
  -- (Script.clear), so none of these arrives: the voices stopped at once with
  -- the engine, without a release
  S.register_cleanup(S.constants.CLEANUP_ORDER.voices_off, function()
    for i = 1, NUM_VOICES do
      if S.voices[i].active then
        engine.voiceOff(i - 1)
        run_voice_stop_hooks(i)
      end
    end
  end)

  M.engine_mod_source = engine_mod_source
  M.with_lfo_offsets = with_lfo_offsets
  M.send_engine_value = send_engine_value
  M.grain_key_message = grain_key_message
  M.reaches_engine = reaches_engine  -- the LFOs' round robin (lib/lfos.lua, #644)

  return M
end

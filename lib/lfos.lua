-- lib/lfos.lua
-- The six global LFOs, Strata's own (3.4; norns' lib/lfo.lua is no longer
-- used): their params (add_lfo_params, which lib/params_setup.lua's lfos
-- record calls: a group strata_lfo_<n> of 12 per LFO), the destination
-- list (S.LFO_DESTINATIONS, by voice: from init a registered one,
-- S.registry.lfo_destinations, joins its voice's group), and the one clock
-- that steps them (S.lfo_clock, 48 Hz, from the start step lfo_clock to the
-- cleanup step lfos). An LFO's destination is its home routing, the
-- matrix's slot 16 + n (S.lib.matrix.home, the groundwork before 3.8): on
-- one of the five fast destinations (a voice's grain pitch, position,
-- size, filter cutoff and level) the LFO runs in the engine (setFastLfo,
-- stopFastLfo, syncFastLfo); on a macro (a direct destination) it hands
-- the macro over itself once a step; on any other the matrix sums it
-- (home_m) with the R routings into one extra offset. Its sends and the
-- matrix's go through one round robin (mark_due), at most
-- LFO.sends_per_step a step (on_step). LFO n's rate and depth can follow a
-- lower-numbered LFO's shape value. Registers the LFOs as modulation
-- sources lfo1..lfo6, the clock's start and cleanup steps and the "lfo
-- clock" invariant. S.selected_lfo is the LFO the LFO page and arc work
-- on. The functions that were global stay global (lfo_destination_id,
-- add_lfo_params); the rest are fields of this module's table
-- (S.lib.lfos).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_LFOS = S.constants.NUM_LFOS

  -- The LFOs' numbers (design 3.4 §1, §2). The clock steps every LFO
  -- step_hz times a second and sends at most sends_per_step values a step;
  -- a Lua-run LFO plays at most lua_max_hz, an engine-run one engine_max_hz;
  -- a Lua send is skipped under send_threshold of its destination's range,
  -- an engine LFO's modulated rate is resent past engine_rate_threshold
  -- (relative) and its depth past send_threshold. A clocked LFO in the
  -- engine is resynced every bar_beats beats. A division of value r is a
  -- period of 4r beats (the library's clocked rates). The fast
  -- destinations' laws (§3.3): half ranges of pitch, position and size;
  -- the cutoff moves by cutoff_ratio per half range, the level by m
  local LFO = {
    step_hz = 48, sends_per_step = 12, lua_max_hz = 10, engine_max_hz = 50,
    send_threshold = 1 / 1000, engine_rate_threshold = 0.005,
    min_hz = 0.003, bar_beats = 4, beats_per_division = 4, drunk_step = 0.2, group_size = 12,
    defaults = {rate = 0.25, depth = 25, division = 13},
    shapes = {"sine", "tri", "square", "up", "down", "s&h", "smooth", "drunk"},
    random_shapes = {["s&h"] = true, smooth = true, drunk = true},
    modes = {"free", "clocked"},
    divisions = {"1/16", "1/8", "1/4", "5/16", "1/3", "3/8", "1/2", "3/4", "1", "1.5", "2", "3", "4", "6", "8", "16",
      "32", "64", "128", "256", "512", "1024"},
    division_values = {1 / 16, 1 / 8, 1 / 4, 5 / 16, 1 / 3, 3 / 8, 1 / 2, 3 / 4, 1, 1.5, 2, 3, 4, 6, 8, 16, 32, 64, 128,
      256, 512, 1024},
    fast_half_ranges = {[0] = 1.875, [1] = 0.5, [2] = 0.245},
    cutoff_ratio = 31.62,
  }
  M.LFO = LFO

  -- A param suffix's engine destination (design §2.3): 0 pitch, 1
  -- position, 2 size, 3 the voice filter's cutoff, 4 the voice's level
  M.FAST_DESTINATIONS = {grain_pitch = 0, buf_pos = 1, grain_size = 2, filter_freq = 3, amp = 4}

  -- LFO n's param ids: strata_lfo<n> (on/off) and strata_lfo<n>_<field>
  local function param_id(n, field)
    if field then return "strata_lfo" .. n .. "_" .. field end
    return "strata_lfo" .. n
  end
  M.param_id = param_id

  S.selected_lfo = 1   -- the LFO page's and the arc's LFO

  -- The voice and engine destination of a fast param (v<i>_grain_pitch,
  -- ...), or nil for any other param
  function M.fast_destination(id)
    local voice, suffix = tostring(id):match("^v(%d+)_(.+)$")
    voice = tonumber(voice)
    local destination = suffix and M.FAST_DESTINATIONS[suffix]
    if not (voice and destination) or voice < 1 or voice > NUM_VOICES then return nil end
    return voice, destination
  end

  -- LFO destinations in the LFO page's order (3.7, design decision 24):
  -- {label, key, resolve, group, fast}, where key is what a home routing
  -- holds (the param id it moves, v<i>_main for a voice's main entry, none
  -- as the home's ""), resolve returns the param id to modulate (nil for
  -- none), group names the group ALT+E3 jumps by (none, global, voice <i>,
  -- macros), and fast is {voice, destination} for an entry that runs in the
  -- engine. A voice's "main" resolves on every step, so it follows the
  -- voice's source, and is never fast (it can resolve to any param: the
  -- matrix sums it)
  local function fixed_destination(label, id, group)
    local voice, destination = M.fast_destination(id)
    return {label = label, key = id, resolve = function() return id end, group = group,
      fast = voice and {voice = voice, destination = destination} or nil}
  end

  -- The built-in destinations: the globals ({label, param id}) and, per
  -- voice after "v<i> main", {label suffix, param id suffix}. A registered
  -- global destination joins the group its registration names (#729): the
  -- macros', which ends the list, or the globals
  local BUILT_IN_DESTINATIONS = {
    globals = {
      {"density", "master_density"}, {"drift", "drift_amount"}, {"filt freq", "filter_freq"},
      {"filt res", "filter_res"}, {"filt mix", "filter_mix"}, {"dly time", "delay_time"},
      {"dly fdbk", "delay_feedback"}, {"dly mix", "delay_mix"}, {"rev mix", "reverb_mix"},
      {"rev size", "reverb_size"}, {"rev damp", "reverb_damp"}
    },
    voice = {
      {"size", "grain_size"}, {"dens", "grain_density"}, {"pitch", "grain_pitch"}, {"spread", "grain_spread"},
      {"pos", "buf_pos"}, {"rate", "buf_rate"}, {"scan", "buf_scan"}
    },
  }

  -- Each destination's index in S.LFO_DESTINATIONS by its key, rebuilt with
  -- the list
  local key_index = {}

  -- Build S.LFO_DESTINATIONS in place from the built-in destinations and
  -- `registered` (S.registry.lfo_destinations at init, none at include
  -- time): none; the globals, built-in then registered; per voice its main
  -- entry, its built-in ones, then each per-voice record's in registration
  -- order; then the macros. Returns the option labels. A label that repeats
  -- one, or a second destination of one param (a key is stored, so it
  -- names one entry), is an error naming the register function
  local function build_destinations(registered)
    for key in pairs(key_index) do key_index[key] = nil end
    local parts = {{}}   -- the globals, voice 1 .. voice NUM_VOICES, the macros
    for i = 1, NUM_VOICES do parts[i + 1] = {} end
    local macros = {}
    parts[NUM_VOICES + 2] = macros
    local taken, keys = {none = true}, {none = true}
    -- kind: the register function the record came from, which an error names
    local function add(part, kind, label, id, group, entry)
      if taken[label] then error(kind .. ": the label " .. label .. " is taken", 0) end
      if keys[id] then error(kind .. ": " .. label .. "'s param " .. id .. " is already a destination", 0) end
      taken[label], keys[id] = true, true
      table.insert(part, entry or fixed_destination(label, id, group))
    end
    for _, entry in ipairs(BUILT_IN_DESTINATIONS.globals) do add(parts[1], "built-in", entry[1], entry[2], "global") end
    for i = 1, NUM_VOICES do
      local group, prefix = "voice " .. i, "v" .. i
      add(parts[i + 1], "built-in", prefix .. " main", prefix .. "_main", group,
        {label = prefix .. " main", key = prefix .. "_main", resolve = function() return main_param_id(i) end,
          group = group})
      for _, entry in ipairs(BUILT_IN_DESTINATIONS.voice) do
        add(parts[i + 1], "built-in", prefix .. " " .. entry[1], prefix .. "_" .. entry[2], group)
      end
    end
    for _, entry in ipairs(registered) do
      if not entry.global then
        for i = 1, NUM_VOICES do
          add(parts[i + 1], "register_lfo_destination", "v" .. i .. " " .. entry.label, "v" .. i .. "_" .. entry.suffix,
            "voice " .. i)
        end
      else
        add(entry.group == "macros" and macros or parts[1], "register_lfo_global_destination", entry.label,
          entry.param_id, entry.group)
      end
    end
    local list = S.LFO_DESTINATIONS
    for index = #list, 1, -1 do list[index] = nil end
    table.insert(list, {label = "none", key = "none", resolve = function() return nil end, group = "none"})
    for _, part in ipairs(parts) do
      for _, destination in ipairs(part) do table.insert(list, destination) end
    end
    local labels = {}
    for index, destination in ipairs(list) do
      labels[index] = destination.label
      key_index[destination.key] = index
    end
    return labels
  end

  -- At include time the built-in ones (the registered ones are read at
  -- init, add_lfo_params), in a table that keeps its identity
  S.LFO_DESTINATIONS = {}
  build_destinations({})

  -- The groups ALT+E3 jumps by, in order, none aside: {name, first, last},
  -- indices into S.LFO_DESTINATIONS (global, voice 1 .. voice 7, macros)
  function M.destination_groups()
    local groups = {}
    for index, destination in ipairs(S.LFO_DESTINATIONS) do
      local last = groups[#groups]
      if destination.group == "none" then
        -- none is a destination of its own, in no group
      elseif last and last.name == destination.group then
        last.last = index
      else
        table.insert(groups, {name = destination.group, first = index, last = index})
      end
    end
    return groups
  end


  -- Each global destination's param exists only once every params record
  -- has run (the macros come after the LFOs): checked at the clock's start
  local function check_global_destinations()
    for _, entry in ipairs(S.registry.lfo_destinations) do
      if entry.global then
        local param = params.lookup[entry.param_id] and params:lookup_param(entry.param_id)
        if not (param and param.t == params.tCONTROL) then
          error("register_lfo_global_destination: " .. entry.label .. "'s param " .. tostring(entry.param_id)
            .. " is not a control param", 0)
        end
      end
    end
  end

  -- The index in S.LFO_DESTINATIONS of LFO n's home routing's destination
  -- (S.lib.matrix.home): 1 (none) for none or a key this build lacks, which
  -- the home keeps and which does not play
  function M.destination_index(n)
    local key = S.lib.matrix.home(n)
    return key and key_index[key] or 1
  end

  -- The home routing's destination id of entry index: "" for none, else
  -- its key
  function M.destination_id(index)
    local destination = S.LFO_DESTINATIONS[index]
    if not destination or destination.key == "none" then return "" end
    return destination.key
  end

  -- LFO n's destination entry, and the param id it modulates now (or nil)
  local function destination_of(n)
    return S.LFO_DESTINATIONS[M.destination_index(n)]
  end
  M.destination = destination_of

  function lfo_destination_id(n)
    return destination_of(n).resolve()
  end

  -- Whether LFO n runs in the engine when it plays: its destination is
  -- fast. Its label then shows "~"
  function M.is_engine_run(n)
    return destination_of(n).fast ~= nil
  end

  function M.label(n)
    local destination = destination_of(n)
    return destination.label .. (destination.fast and "~" or "")
  end

  local function is_on(n) return params:get(param_id(n)) == 1 end
  M.is_on = is_on

  local function is_clocked(n) return params:get(param_id(n, "mode")) == 2 end
  M.is_clocked = is_clocked

  -- The first LFO of the LFO page's window of three around `selected`
  function M.window(selected)
    return util.clamp(selected - 1, 1, NUM_LFOS - 2)
  end

  -- Per LFO, the clock's state: the free phase (position, 0..1, before the
  -- phase param) and when it was last advanced; a clocked LFO's phase
  -- offset (cycles its rate modulation added) and the beats it was last
  -- read at; the phase and value of the last step; the random shapes' two
  -- draws (from, to: a cycle goes from one to the other); the rate and
  -- depth it plays (rate', depth', design §2.4); what the engine holds for
  -- it (engine: {voice, destination, shape, rate, depth, offset}, nil
  -- without a node), whether a hand edit or a phase move waits for the
  -- next step (edited, sync_due) or an edit by a deferrable source for the
  -- round robin (deferred), the phase param the engine was last synced to
  -- or will be (phase_seen: a phase set without its action, a silent read,
  -- is caught by it), and the bar it was last synced in
  local state = {}
  for n = 1, NUM_LFOS do
    state[n] = {position = 0, last_time = nil, clocked_offset = 0, last_beats = nil, phase = 0, value = 0,
      stepped = false, from = 0.5, to = 0.5, rate = LFO.defaults.rate, depth = LFO.defaults.depth, engine = nil,
      edited = false, sync_due = false, deferred = false, phase_seen = nil, bar = nil}
  end

  -- A deterministic shape's u (0..1) at phase (0..1), design §2.2
  local function shape_u(shape, phase)
    if shape == 1 then return (math.sin(2 * math.pi * phase) + 1) / 2 end
    if shape == 2 then return phase < 0.5 and 2 * phase or 2 - 2 * phase end
    if shape == 3 then return phase < 0.5 and 1 or 0 end
    if shape == 4 then return phase end
    return 1 - phase
  end
  M.shape_u = shape_u

  local function reflect(u)
    if u < 0 then return -u end
    if u > 1 then return 2 - u end
    return u
  end

  -- A random shape's next draw: s&h and smooth a uniform value, drunk the
  -- last plus a step of up to drunk_step either way, reflected into 0..1
  local function draw(n)
    if params:string(param_id(n, "shape")) == "drunk" then
      return reflect(state[n].to + (2 * math.random() - 1) * LFO.drunk_step)
    end
    return math.random()
  end

  local function new_cycle(n)
    local st = state[n]
    st.from = st.to
    st.to = draw(n)
  end

  -- u of LFO n's shape at phase: a random shape from its cycle's draws
  local function lfo_u(n, phase)
    local shape = params:get(param_id(n, "shape"))
    local name = LFO.shapes[shape]
    if name == "s&h" then return state[n].to end
    if LFO.random_shapes[name] then return state[n].from + (state[n].to - state[n].from) * phase end
    return shape_u(shape, phase)
  end

  -- The shape value (2u - 1) of a mod source option: 1 none, k LFO k - 1
  -- (0 while it is off)
  local function source_value(option)
    if option <= 1 then return 0 end
    return state[option - 1].value
  end

  -- The clock's beat length now (a clocked rate): the clock_tempo param on
  -- the internal clock, so a tempo change counts at once (#567)
  local function beat_seconds()
    return S.lib.params_setup.beat_seconds_now()
  end

  local function period_beats(n)
    return LFO.division_values[params:get(param_id(n, "division"))] * LFO.beats_per_division
  end

  -- LFO n's unmodulated rate in Hz: the rate param (free) or its division
  -- at the tempo (clocked)
  local function base_rate(n)
    if is_clocked(n) then return 1 / (period_beats(n) * beat_seconds()) end
    return params:get(param_id(n, "rate"))
  end
  M.base_rate = base_rate

  -- The rate and depth LFO n plays (design §2.4): its rate times 4 ^
  -- (amount x source), between min_hz and the run's ceiling, and its depth
  -- times 1 + amount x source, between 0 and 100
  local function evaluate(n)
    local st = state[n]
    local rate_amount = params:get(param_id(n, "rate_mod_amt")) / 100
    local depth_amount = params:get(param_id(n, "depth_mod_amt")) / 100
    local ceiling = M.is_engine_run(n) and LFO.engine_max_hz or LFO.lua_max_hz
    local rate_source = source_value(params:get(param_id(n, "rate_mod")))
    local depth_source = source_value(params:get(param_id(n, "depth_mod")))
    st.base = base_rate(n)
    st.rate = util.clamp(st.base * 4 ^ (rate_amount * rate_source), LFO.min_hz, ceiling)
    st.depth = util.clamp(params:get(param_id(n, "depth")) * (1 + depth_amount * depth_source), 0, 100)
  end

  function M.effective_rate(n) return state[n].rate end
  function M.effective_depth(n) return state[n].depth end

  -- Whether LFO n runs in Lua above lua_max_hz (the page's "max")
  function M.capped(n)
    return not M.is_engine_run(n) and base_rate(n) > LFO.lua_max_hz
  end

  -- LFO n's phase now (0..1, the phase param included; 0 while off): a
  -- free LFO's from its last step and the time since, a clocked one's from
  -- the beats
  function M.phase(n)
    if not is_on(n) then return 0 end
    local st = state[n]
    local offset = params:get(param_id(n, "phase")) / 100
    if is_clocked(n) then
      return (clock.get_beats() / period_beats(n) + st.clocked_offset + offset) % 1
    end
    local elapsed = st.last_time and math.max(0, util.time() - st.last_time) or 0
    return (st.position + st.rate * elapsed + offset) % 1
  end

  -- LFO n's shape value 2u - 1 at its last step: what a modulated LFO and
  -- a matrix routing read; 0 while it is off
  function M.value(n) return state[n].value end

  -- Whether LFO n has stepped since it was turned on (the page's dot)
  function M.has_stepped(n) return state[n].stepped end

  ---------------------------------------------------------------------------
  -- The send queue: due keys sent in one round robin, at most
  -- sends_per_step a step, in the order each key was first marked, each
  -- send inside S.lib.engine_sync.deferrable (it can wait for the budget).
  -- A key that reaches no engine (a stopped voice's param:
  -- S.lib.engine_sync.reaches_engine) still runs in its turn, so its value
  -- is recorded, but takes no slot (#644)
  ---------------------------------------------------------------------------
  local queue = {keys = {}, known = {}, due = {}, cursor = 1}

  -- send() goes out in the round robin under key; a later mark of the same
  -- key replaces it
  function M.mark_due(key, send)
    if not queue.known[key] then
      table.insert(queue.keys, key)
      queue.known[key] = true
    end
    queue.due[key] = send
  end

  local send_errors = {}  -- per key: the error its send last printed
  local function drain()
    local count = #queue.keys
    if count == 0 then return end
    local position = ((queue.cursor - 1) % count) + 1
    local sent = 0
    for _ = 1, count do
      if sent >= LFO.sends_per_step then break end
      local key = queue.keys[position]
      local send = queue.due[key]
      if send then
        queue.due[key] = nil
        if S.lib.engine_sync.reaches_engine(key) then sent = sent + 1 end
        S.lib.ui_frame.contained_call(send_errors, key, "LFO send", S.lib.engine_sync.deferrable, send)
      end
      position = position % count + 1
    end
    queue.cursor = position
  end

  -- fn() runs in every clock step after the six LFOs (the matrix's)
  local step_hooks = {}
  function M.on_step(fn)
    assert(type(fn) == "function", "S.lib.lfos.on_step: a hook is a function")
    table.insert(step_hooks, fn)
  end

  ---------------------------------------------------------------------------
  -- Lua-run LFOs: modulating around the stored value
  ---------------------------------------------------------------------------

  -- Destinations whose engine sender reaches no engine (a macro's, which
  -- works out its targets' extras: lib/macros.lua) take no round-robin slot
  -- and no budget message (#636): an LFO homed on one runs that sender
  -- itself (S.engine_senders[id]), once a step after the six LFOs when the
  -- modulated value moved by send_threshold from the one it last handed
  -- over (last[id]), and at once at a restore. ids in registration order;
  -- due[id] while a step's LFO moved it; held[n] the one LFO n holds
  local direct = {known = {}, ids = {}, last = {}, due = {}, held = {}}
  local send_direct  -- (id, always): below, once destination_position is

  function M.direct_destination(param_id)
    assert(type(param_id) == "string", "S.lib.lfos.direct_destination: a param id is a string")
    assert(not direct.known[param_id], "S.lib.lfos.direct_destination: " .. param_id .. " is registered")
    direct.known[param_id] = true
    table.insert(direct.ids, param_id)
  end

  -- LFO n lets the direct destination it holds go: its sender gets the
  -- stored value back (plus any other LFO's offset on it), at once. A Lua
  -- destination is given back by the matrix's next step
  local function release_direct(n)
    local id = direct.held[n]
    if not id then return end
    direct.held[n] = nil
    send_direct(id, true)
  end

  -- Whether an LFO holds direct destination id now (an LFO on a macro)
  function M.modulates(id)
    for n = 1, NUM_LFOS do
      if direct.held[n] == id then return true end
    end
    return false
  end

  -- Whether LFO n's home routing to id is this module's to play: its home
  -- is fast and resolves to id (its engine node), or id is a direct
  -- destination (a macro, handed over in its step). Whatever its on/off
  -- and depth, as S.lib.envelopes.owns is about kind
  function M.owns(n, id)
    if type(n) ~= "number" or n < 1 or n > NUM_LFOS or n % 1 ~= 0 or id == nil then return false end
    if direct.known[id] then return true end
    local destination = destination_of(n)
    return destination.fast ~= nil and destination.resolve() == id
  end

  -- The offset of a Lua destination for m half ranges (the matrix's too)
  function M.offset_for(id, m)
    local minval, maxval = param_range(id)
    return m * 0.5 * (maxval - minval)
  end

  -- The m (in half ranges) that moves a destination from base to value: a
  -- fast destination's by its law (pitch, position and size linear, the
  -- cutoff in ratios of cutoff_ratio, the level by value / base - 1, 0 at
  -- base 0), a Lua destination's by half its range
  function M.m_for(id, base, value)
    local _, destination = M.fast_destination(id)
    if destination == 3 then
      if base <= 0 or value <= 0 then return 0 end
      return math.log(value / base) / math.log(LFO.cutoff_ratio)
    elseif destination == 4 then
      if base == 0 then return 0 end
      return value / base - 1
    elseif destination then
      return (value - base) / LFO.fast_half_ranges[destination]
    end
    local minval, maxval = param_range(id)
    if maxval == minval then return 0 end
    return (value - base) / (0.5 * (maxval - minval))
  end

  -- A value's position (0-1) along a destination's range, as its
  -- controlspec's warp places it (an exponential range in octaves), without
  -- the rounding to the param's step that unmap does first: a move finer
  -- than the step must count (a 0.01-step mix still sends every 1/1000).
  -- So it unmaps with a copy of the spec whose step is 0, made once per
  -- spec (keyed weakly by the spec itself); the param's own spec is never
  -- changed (#406)
  local unstepped_specs = setmetatable({}, {__mode = "k"})
  local function destination_position(id, value)
    local spec = params:lookup_param(id).controlspec
    local unstepped = unstepped_specs[spec]
    if not unstepped then
      unstepped = spec:copy()
      unstepped.step = 0
      unstepped_specs[spec] = unstepped
    end
    return unstepped:unmap(value)
  end

  -- A direct destination's modulated value to its sender (always: a
  -- restore's, whatever it last handed over)
  send_direct = function(id, always)
    local value = M.direct_value(id)
    local last = direct.last[id]
    if not always and last ~= nil
      and math.abs(destination_position(id, value) - destination_position(id, last)) < LFO.send_threshold then
      return
    end
    direct.last[id] = value
    S.engine_senders[id](value)
  end

  -- LFO n's m on its home routing (design §2.2: value x depth' / 100 + 2 x
  -- offset / 100, in half ranges) while it is on at a depth above 0, else
  -- nil: what the matrix sums for a Lua home and a direct destination adds
  function M.home_m(n)
    if not is_on(n) or params:get(param_id(n, "depth")) <= 0 then return nil end
    local st = state[n]
    return st.value * st.depth / 100 + 2 * params:get(param_id(n, "offset")) / 100
  end

  -- A direct destination's modulated value: its stored value plus the
  -- offset of every LFO holding it, clamped once to its range (a macro
  -- param has no override, extra or factor)
  function M.direct_value(id)
    local value, offset, modulated = params:get(id), 0, false
    for n = 1, NUM_LFOS do
      local m = direct.held[n] == id and M.home_m(n)
      if m then
        offset = offset + M.offset_for(id, m)
        modulated = true
      end
    end
    if not modulated then return value end
    return util.clamp(value + offset, param_range(id))
  end

  -- An LFO not run in the engine: on a direct destination it holds it and
  -- marks it due (handed over after the six LFOs); a home that resolves
  -- elsewhere, plays nothing (off, depth 0: a silent read sets the depth
  -- without its action) or is the matrix's gives the held one back first
  -- (a direct destination is a fixed entry: its key is its id, so nothing
  -- is resolved here; a resolve that raises is the matrix's to contain)
  local function step_direct(n)
    local id = destination_of(n).key
    local playing = M.home_m(n) ~= nil and direct.known[id]
    if direct.held[n] and (not playing or direct.held[n] ~= id) then release_direct(n) end
    if not playing then return end
    direct.held[n] = id
    direct.due[id] = true
  end

  ---------------------------------------------------------------------------
  -- Engine-run LFOs (design §2.6)
  ---------------------------------------------------------------------------
  local function engine_key(n) return "lfo" .. n .. " engine" end

  -- Whether LFO n plays in the engine now: on, on a fast destination, at a
  -- depth above 0
  local function engine_playing(n)
    return is_on(n) and M.is_engine_run(n) and params:get(param_id(n, "depth")) > 0
  end
  M.engine_playing = engine_playing  -- MAIN's ~ (lib/pages/main.lua) reads this one answer

  local function engine_want(n)
    local st, fast = state[n], destination_of(n).fast
    return {voice = fast.voice, destination = fast.destination, shape = params:get(param_id(n, "shape")) - 1,
      rate = st.rate, depth = st.depth / 100, base = st.base,
      offset = util.clamp(2 * params:get(param_id(n, "offset")) / 100, -2, 2)}
  end

  local function send_fast_lfo(n, want)
    engine.setFastLfo(n - 1, want.voice - 1, want.destination, want.shape, want.rate, want.depth, want.offset)
    state[n].engine = want
    queue.due[engine_key(n)] = nil
  end

  -- What goes through the round robin goes through the send budget too
  -- (#633): each LFO's setFastLfo and syncFastLfo are deferrable ids of the
  -- budget under these keys (no param id holds a space), whose engine
  -- senders read LFO n's settings and phase when they deliver (a value that
  -- waited for the next window is never an older one) and send nothing once
  -- its node has gone. The round robin's sends, made once per LFO, hand the
  -- key to S.lib.engine_sync.send_engine_value inside deferrable: counted,
  -- and past the budget waiting for the next window
  local function sync_key(n) return "lfo" .. n .. " sync" end
  local function has_node(n) return engine_playing(n) and state[n].engine ~= nil end
  local engine_sends, sync_sends = {}, {}
  for n = 1, NUM_LFOS do
    S.engine_senders[engine_key(n)] = function()
      if has_node(n) then send_fast_lfo(n, engine_want(n)) end
    end
    S.engine_senders[sync_key(n)] = function()
      if has_node(n) then engine.syncFastLfo(n - 1, M.phase(n)) end
    end
    engine_sends[n] = function()
      if has_node(n) then S.lib.engine_sync.send_engine_value(engine_key(n), state[n].depth / 100) end
    end
    sync_sends[n] = function()
      if has_node(n) then S.lib.engine_sync.send_engine_value(sync_key(n), M.phase(n)) end
    end
  end

  -- Whether a clocked LFO's base rate (its division at the tempo) moved past
  -- engine_rate_threshold since the engine got it: a tempo change, sent in
  -- the step that sees it, ahead of the round robin, so a tempo change reaches it within one step
  local function tempo_moved(n, want, sent)
    return is_clocked(n) and sent.base ~= nil and want.base ~= nil
      and math.abs(want.base - sent.base) > sent.base * LFO.engine_rate_threshold
  end

  -- Bring the engine to LFO n's settings: a start, a stop, a new voice,
  -- destination or shape, a hand edit (edited) or a clocked LFO's new tempo
  -- at once, outside the round robin (at most one send per LFO a step); an
  -- edit by a deferrable source (deferred: a macro, morph, gesture playback,
  -- a fade), a modulated rate past engine_rate_threshold, a depth past
  -- send_threshold and an offset that moved (a silent read sets it without
  -- its action, #634) through the round robin and the send budget; then the
  -- sync a start, a restart, a shape or phase change or a bar asked for, at
  -- once, or through the round robin for a phase param that moved without a
  -- hand edit (a deferrable source's, a silent read's)
  local function reconcile_engine(n)
    local st = state[n]
    if not engine_playing(n) then
      if st.engine then engine.stopFastLfo(n - 1) end
      st.engine, st.edited, st.sync_due, st.deferred, st.phase_seen = nil, false, false, false, nil
      queue.due[engine_key(n)], queue.due[sync_key(n)] = nil, nil
      return
    end
    local want, sent = engine_want(n), st.engine
    if not sent or st.edited or want.voice ~= sent.voice or want.destination ~= sent.destination
      or want.shape ~= sent.shape or tempo_moved(n, want, sent) then
      if not sent or want.shape ~= sent.shape then st.sync_due = true end
      send_fast_lfo(n, want)
      st.edited, st.deferred = false, false
    elseif st.deferred or math.abs(want.rate - sent.rate) > sent.rate * LFO.engine_rate_threshold
      or math.abs(want.depth - sent.depth) > LFO.send_threshold
      or math.abs(want.offset - sent.offset) > LFO.send_threshold then
      st.deferred = false
      M.mark_due(engine_key(n), engine_sends[n])
    end
    local phase_param = params:get(param_id(n, "phase"))
    if st.sync_due then
      st.sync_due = false
      queue.due[sync_key(n)] = nil
      engine.syncFastLfo(n - 1, M.phase(n))
    elseif phase_param ~= st.phase_seen then
      M.mark_due(sync_key(n), sync_sends[n])
    end
    st.phase_seen = phase_param
  end

  ---------------------------------------------------------------------------
  -- The clock
  ---------------------------------------------------------------------------

  -- The clock's reading of the beats, taken once a step when a clocked LFO
  -- needs it: beats lower than at the last step (a transport start) resync
  -- every clocked engine LFO (design §8.11)
  local beats_reading = {last = nil}

  local function read_beats(step)
    if step.beats == nil then
      step.beats = clock.get_beats()
      step.fell = beats_reading.last ~= nil and step.beats < beats_reading.last
    end
    return step.beats
  end

  -- One step of LFO n: its phase advances (a free one by the rate it
  -- played since the last step, a clocked one from the beats), a wrap
  -- draws a random shape's next value, then its value, its rate and depth,
  -- and its destination's send (Lua) or the engine's settings
  local function step_lfo(n, now, step)
    local st = state[n]
    if not is_on(n) then
      st.value = 0
      release_direct(n)
      if st.engine then reconcile_engine(n) end
      return
    end
    local previous = st.phase
    local offset = params:get(param_id(n, "phase")) / 100
    local phase
    if is_clocked(n) then
      local beats = read_beats(step)
      local multiplier = st.base and st.base > 0 and st.rate / st.base or 1
      if st.last_beats and beats >= st.last_beats and multiplier ~= 1 then
        st.clocked_offset = (st.clocked_offset + (beats - st.last_beats) / period_beats(n) * (multiplier - 1)) % 1
      end
      st.last_beats = beats
      phase = (beats / period_beats(n) + st.clocked_offset + offset) % 1
    else
      local elapsed = st.last_time and math.max(0, now - st.last_time) or 0
      st.position = (st.position + st.rate * elapsed) % 1
      phase = (st.position + offset) % 1
    end
    st.last_time = now
    if st.stepped and phase < previous then new_cycle(n) end
    st.phase = phase
    st.value = 2 * lfo_u(n, phase) - 1
    st.stepped = true
    evaluate(n)
    if M.is_engine_run(n) then
      if is_clocked(n) and engine_playing(n) then
        local bar = math.floor(read_beats(step) / LFO.bar_beats)
        if step.fell or (st.bar ~= nil and bar ~= st.bar) then st.sync_due = true end
        st.bar = bar
      end
      release_direct(n)
      reconcile_engine(n)
    else
      if st.engine then reconcile_engine(n) end
      step_direct(n)
    end
  end

  -- Each LFO's step and each hook, protected: one error never stops the
  -- others or the clock (#517). It is printed with its traceback once per
  -- distinct message per LFO (a good step forgets it)
  local step_errors, hook_errors = {}, {}
  local function step_all()
    local now = util.time()
    local step = {}
    for n = 1, NUM_LFOS do
      S.lib.ui_frame.contained_call(step_errors, n, "LFO " .. n .. " step", step_lfo, n, now, step)
    end
    -- the direct destinations the LFOs moved, each once with every LFO's offset
    for _, id in ipairs(direct.ids) do
      if direct.due[id] then
        direct.due[id] = nil
        S.lib.ui_frame.contained_call(send_errors, id, "LFO send", send_direct, id, false)
      end
    end
    beats_reading.last = step.beats
    for index, fn in ipairs(step_hooks) do
      S.lib.ui_frame.contained_call(hook_errors, index, "LFO step hook", fn)
    end
    drain()
  end

  -- The clock runs from its start step to cleanup (the invariant); sleep
  -- is outside every deferrable write
  local clock_runs = false
  S.lfo_clock = nil

  -- Stop the clock (cleanup's first part; a test that wants a quiet
  -- scheduler calls it too)
  local function stop_clock()
    clock_runs = false
    if S.lfo_clock then
      clock.cancel(S.lfo_clock)
      S.lfo_clock = nil
    end
  end
  M.stop_clock = stop_clock

  S.register_start(S.constants.START_ORDER.lfo_clock, function()
    check_global_destinations()
    if S.lfo_clock then clock.cancel(S.lfo_clock) end
    clock_runs = true
    S.lfo_clock = clock.run(function()
      while true do
        clock.sleep(1 / LFO.step_hz)
        step_all()
      end
    end)
  end)

  -- The clock runs from its start step to cleanup or stop_clock, and its
  -- coroutine with it (clock.threads, as norns' clock keeps them): a clock
  -- canceled or ended behind the module's back breaks it
  S.register_invariant("lfo clock", function()
    if clock_runs and S.lfo_clock == nil then return "the LFO clock stopped before cleanup" end
    if not clock_runs and S.lfo_clock ~= nil then return "the LFO clock runs outside its start step and cleanup" end
    if clock_runs and clock.threads then
      local thread = clock.threads[S.lfo_clock]
      if type(thread) ~= "thread" or coroutine.status(thread) == "dead" then
        return "the LFO clock " .. tostring(S.lfo_clock) .. " is not running (canceled or ended) before cleanup"
      end
    end
  end)

  -- Cleanup (step 120): the clock stops and nothing waits to be sent.
  -- norns has freed the engine by then (#461), and an engine LFO's node
  -- with it, so nothing stops one; every direct destination is given back
  -- (the matrix's cleanup step forgets the Lua ones' offsets; none of it
  -- arrives on the device)
  S.register_cleanup(S.constants.CLEANUP_ORDER.lfos, function()
    stop_clock()
    queue.due = {}
    for n = 1, NUM_LFOS do
      state[n].engine = nil
      release_direct(n)
    end
  end)

  ---------------------------------------------------------------------------
  -- Params
  ---------------------------------------------------------------------------

  -- LFO n turned on: its phase starts at the phase param (a free LFO's
  -- position at 0), the random shapes draw afresh, and the engine starts it
  -- on a fast destination; turned off: a direct destination gets its stored
  -- value back at once, a Lua one at the matrix's next step
  local function turned(n, on)
    local st = state[n]
    if on then
      st.position, st.last_time, st.clocked_offset, st.last_beats = 0, util.time(), 0, nil
      st.stepped = false
      local shape = params:string(param_id(n, "shape"))
      if shape == "drunk" then
        st.from, st.to = 0.5, 0.5
      elseif LFO.random_shapes[shape] then
        st.from, st.to = math.random(), math.random()
      end
      st.phase = M.phase(n)
      st.value = 2 * lfo_u(n, st.phase) - 1
      evaluate(n)
      st.bar = is_clocked(n) and math.floor(clock.get_beats() / LFO.bar_beats) or nil
      st.sync_due = true   -- a restart of a running engine LFO (a bang, #251) moves its phase too
    else
      release_direct(n)
      st.value, st.stepped = 0, false
    end
    reconcile_engine(n)
  end

  -- A setting the engine needs at once (an option or binary param: their
  -- actions may call the engine). While a scene applies (a recall, a fade's
  -- end, morph's discrete entries: S.scene_recall_in_progress) it is only
  -- marked: the scene's other settings of the LFO (its home routing, rate,
  -- depth, ...) are not all in place yet, so the next step sends the LFO
  -- once with every one of them, never a mix of old and new (0e's review)
  local function settings_changed(n, sync)
    if not is_on(n) then return end
    if sync then state[n].sync_due = true end
    state[n].edited = true
    if S.scene_recall_in_progress then return end
    evaluate(n)
    reconcile_engine(n)
  end

  -- LFO n's home routing changed (S.lib.matrix.set_home, a load or an
  -- apply of the matrix's block): a direct destination it held is given
  -- back at once, and the engine gets the LFO's settings (only marked while
  -- a scene applies). A Lua destination is the matrix's from its next step
  function M.home_changed(n)
    release_direct(n)
    settings_changed(n, false)
  end

  -- A control param's edit (rate, depth, offset, phase, mod amounts): the
  -- next step sends it (a control param's action never calls the engine),
  -- at once for a hand edit; an edit made while S.deferrable_write is set
  -- (a macro apply, morph, gesture playback, a fade) through the round robin
  -- and the send budget (#633), a phase edit as a sync alone (its param
  -- moved from phase_seen: reconcile_engine)
  local function edited(n, sync)
    local st = state[n]
    if S.deferrable_write then
      if not sync then st.deferred = true end
      return
    end
    st.edited = true
    if sync then st.sync_due = true end
  end

  local function signed_percent(param)
    local value = param:get()
    return string.format(value > 0 and "+%.0f%%" or "%.0f%%", value)
  end

  local function add_percent(n, field, name, low, high, default, action)
    params:add{type = "control", id = param_id(n, field), name = name,
      controlspec = controlspec.new(low, high, "lin", 1, default, "%", 1 / (high - low)),
      formatter = low < 0 and signed_percent or nil, action = action}
  end

  local function mod_options(n)
    local options = {"none"}
    for source = 1, n - 1 do options[#options + 1] = "L" .. source end
    return options
  end

  -- LFO n's 12 params, in a group of its own (groups cannot nest): on,
  -- shape, mode, rate, division, depth, offset, phase, and the rate and
  -- depth inputs with their amounts (its destination is its home routing,
  -- the matrix's). The shape, rate, division and phase actions call
  -- note_param_edit (the LFO page's randomize sets them, #557)
  local function add_lfo_group(n)
    params:add_group("strata_lfo_" .. n, "LFO " .. n, LFO.group_size)
    params:add{type = "binary", behavior = "toggle", id = param_id(n), name = "on", default = 0,
      action = function(x) turned(n, x == 1) end}
    params:add{type = "option", id = param_id(n, "shape"), name = "shape", options = LFO.shapes, default = 1,
      action = function()
        note_param_edit(param_id(n, "shape"))
        settings_changed(n, false)
      end}
    params:add{type = "option", id = param_id(n, "mode"), name = "mode", options = LFO.modes, default = 1,
      action = function()
        state[n].clocked_offset, state[n].last_beats = 0, nil
        if n == S.selected_lfo then forget_arc_lfo_period_ticks() end  -- ring 4 was on the other mode's param
        settings_changed(n, true)
      end}
    params:add{type = "control", id = param_id(n, "rate"), name = "rate",
      controlspec = controlspec.new(LFO.min_hz, LFO.engine_max_hz, "exp", 0, LFO.defaults.rate, "Hz"),
      formatter = function(param) return string.format("%.3g Hz", param:get()) end,
      action = function()
        note_param_edit(param_id(n, "rate"))
        edited(n, false)
      end}
    params:add{type = "option", id = param_id(n, "division"), name = "clocked rate", options = LFO.divisions,
      default = LFO.defaults.division,
      action = function()
        note_param_edit(param_id(n, "division"))
        settings_changed(n, is_clocked(n))
      end}
    add_percent(n, "depth", "depth", 0, 100, LFO.defaults.depth, function(depth)
      if depth == 0 then release_direct(n) end
      edited(n, false)
    end)
    add_percent(n, "offset", "offset", -100, 100, 0, function() edited(n, false) end)
    add_percent(n, "phase", "phase", 0, 100, 0, function()
      note_param_edit(param_id(n, "phase"))
      edited(n, true)
    end)
    params:add{type = "option", id = param_id(n, "rate_mod"), name = "rate mod", options = mod_options(n), default = 1,
      action = function() settings_changed(n, false) end}
    add_percent(n, "rate_mod_amt", "rate mod amount", -100, 100, 0, function() edited(n, false) end)
    params:add{type = "option", id = param_id(n, "depth_mod"), name = "depth mod", options = mod_options(n), default = 1,
      action = function() settings_changed(n, false) end}
    add_percent(n, "depth_mod_amt", "depth mod amount", -100, 100, 0, function() edited(n, false) end)
  end

  -- PARAMS: one group per LFO (lib/params_setup.lua's lfos record), after
  -- the destination list is built whole, the registered destinations
  -- included
  function add_lfo_params()
    build_destinations(S.registry.lfo_destinations)
    for n = 1, NUM_LFOS do add_lfo_group(n) end
  end

  ---------------------------------------------------------------------------
  -- Scenes
  ---------------------------------------------------------------------------

  -- The LFOs' scene fields, which lib/scenes.lua appends to
  -- S.SCENE_GLOBAL_PARAMS after its built-in globals (the same records, in
  -- this order). Per LFO, in recall order: its settings, then the state,
  -- so an LFO starts with its settings in place; the destination is its
  -- home routing, in the matrix's block, set before them and brought in by
  -- the next step with them all. Rate,
  -- depth and offset crossfade (lfo = n: the LFO they belong to), except
  -- toward a scene that stops the running LFO (M.transition_stops): its
  -- depth fades to stop_target (0) and the others hold (#408); the rest
  -- switch at a transition's end. range is the {min, max} validate_scene
  -- allows; default is each param's, what a scene without the field loads
  local SCENE_FIELDS = {}
  for n = 1, NUM_LFOS do
    local function field(name, record)
      record.id = param_id(n, name)
      table.insert(SCENE_FIELDS, record)
    end
    field("shape", {continuous = false, default = 1})
    field("mode", {continuous = false, default = 1})
    field("division", {continuous = false, default = LFO.defaults.division})
    field("rate", {continuous = true, lfo = n, default = LFO.defaults.rate, range = {LFO.min_hz, LFO.engine_max_hz}})
    field("depth", {continuous = true, lfo = n, stop_target = 0, default = LFO.defaults.depth, range = {0, 100}})
    field("offset", {continuous = true, lfo = n, default = 0, range = {-100, 100}})
    field("phase", {continuous = false, default = 0, range = {0, 100}})
    field("rate_mod", {continuous = false, default = 1})
    field("rate_mod_amt", {continuous = false, default = 0, range = {-100, 100}})
    field("depth_mod", {continuous = false, default = 1})
    field("depth_mod_amt", {continuous = false, default = 0, range = {-100, 100}})
    table.insert(SCENE_FIELDS, {id = param_id(n), continuous = false, default = 0, range = {0, 1}})
  end
  M.SCENE_FIELDS = SCENE_FIELDS

  -- Whether a smooth transition to scene_data stops LFO n: it runs now and
  -- is off in the scene (lib/scenes.lua's scene_transition_targets)
  function M.transition_stops(n, scene_data)
    return is_on(n) and scene_data[param_id(n)] == 0
  end

  ---------------------------------------------------------------------------
  -- Modulation sources (design §10.1)
  ---------------------------------------------------------------------------

  -- MOD's row text: the home routing's destination (~ in the engine), the depth and the
  -- LFOs its rate and depth follow (v3 pitch~ 25% <L2)
  function M.describe(n)
    local inputs = ""
    for _, input in ipairs({"rate_mod", "depth_mod"}) do
      local option = params:get(param_id(n, input))
      if option > 1 then inputs = inputs .. "<L" .. (option - 1) end
    end
    local text = M.label(n) .. " " .. string.format("%.0f%%", params:get(param_id(n, "depth")))
    if inputs ~= "" then text = text .. " " .. inputs end
    return text
  end

  for n = 1, NUM_LFOS do
    local depth_id = param_id(n, "depth")
    S.register_mod_source({key = "lfo" .. n, name = "L" .. n, section = "lfos", range = {-1, 1},
      value = function() return M.value(n) end,
      describe = function() return M.describe(n) end,
      row = {
        enc = function(d) delta_with_detent(depth_id, d) end,
        fine_enc = function(d) delta_with_detent(depth_id, d, {fine = true}) end,
        press = function() S.lib.pages_lfo.show_lfo(n) end,
        hints = function() return "K3:lfo E3:depth" end,
      }})
  end

  return M
end

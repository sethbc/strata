-- test/modulation_model.lua
-- A model of the engine's modulation nodes (3.9's package 3c, #916), for
-- the walk that compares what Lua handed the engine with what the params
-- imply. Fed the engine calls the stub records (setFastLfo, stopFastLfo,
-- syncFastLfo, setFastOffset, setFastEnv, stopFastEnv, setScatter; and
-- voiceOn, retrigger and noteOn as the engine's hits), it keeps what the
-- modulation and envelopes areas keep (docs/notes/engine/modulation.md,
-- docs/notes/engine/envelopes.md): per engine LFO whether a node runs and
-- its last settings, per channel (voice, destination) its last offset, per
-- route its settings or none, scatter's last state, and per voice the time
-- of its last hit as the feed saw it. A command the engine's guards ignore
-- (an index out of range, a value that is not finite: fastModIndicesValid,
-- fastModValuesFinite) changes nothing here, as there, and is an error, as
-- is one the engine takes as a no-op that Lua sends only while it believes
-- a node runs (a stop or a sync with no node). compare(S, allow) gives
-- where the engine differs from what the params imply, each difference a
-- line; allow names the differences a walk allows while their fault is
-- open or while a send is legally on its way, each counted in
-- model.allowed. Lua's own records (state[n].engine, the budget's) are
-- never read: the params, the matrix's routings and Lua's LFO and
-- envelope values (the sources) are. A test-side helper, not part of the
-- shared stub. Used by test/unit/modulation_walk_test.lua.

local Model = {}
Model.__index = Model

-- The engine's command ranges (AGENTS.md's command table): what it clips
-- to, so a value Lua sends outside them is a value the engine changed
local ENGINE = {
  rate = { 0.003, 50 }, depth = { 0, 1 }, offset = { -2, 2 },
  env_depth = { -2, 2 }, sustain = { 0, 1 }, curve = { -8, 8 },
  scatter_depth = { 0, 1 }, scatter_rate = { 0.01, 1 },
  ulp = 1e-9,                -- a relative difference no tolerance is: two values the same but for rounding
}
Model.ENGINE = ENGINE

-- The hits the engine fires routes on (docs/notes/engine/structure.md, A
-- hit on a voice): a start, a retrigger, an extra note's start
local HITS = { voiceOn = true, retrigger = true, noteOn = true }

-- constants: S.constants (NUM_VOICES, ENVELOPES' times); engine: the
-- engine's own numbers, h.engine_spec (read from its source by the stub):
-- its LFOs, shapes, fast destinations, note slots a channel takes
-- (fastModNoteSlots) and envelope routes, which bound its guards
function Model.new(constants, engine)
  assert(type(constants) == "table" and type(constants.ENVELOPES) == "table", "Model.new: constants is S.constants")
  assert(type(engine) == "table" and type(engine.fast_mod_note_slots) == "number"
    and type(engine.num_fast_lfo_shapes) == "number", "Model.new: engine is h.engine_spec")
  local model = setmetatable({
    lfo_count = engine.num_fast_lfos, voice_count = constants.NUM_VOICES, shapes = engine.num_fast_lfo_shapes,
    destinations = engine.num_fast_destinations, route_count = engine.num_env_routes,
    note_slots = engine.fast_mod_note_slots,
    times = { constants.ENVELOPES.time_min, constants.ENVELOPES.time_max },
    lfos = {}, offsets = {}, routes = {}, scatter = nil, hits = {}, ended = {}, ended_runs = {}, read = 0, errors = {}, allowed = {},
    counts = { lfo_started = 0, lfo_stopped = 0, lfo_replaced = 0, lfo_moved = 0, lfo_synced = 0, offsets_sent = 0,
      routes_set = 0, routes_moved = 0, routes_stopped = 0, scatter_sent = 0, hits = 0, envelopes_ended = 0 },
  }, Model)
  for voice = 0, constants.NUM_VOICES - 1 do
    model.offsets[voice] = {}
    for destination = 0, engine.num_fast_destinations - 1 do model.offsets[voice][destination] = 0 end
  end
  -- a running node set to depth 0, kept (#925: offset 0 with it, it plays nothing)
  model.counts.lfo_at_zero = 0
  return model
end

function Model:error(text) table.insert(self.errors, text) end

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function whole(value, last)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= last
end

-- Whether the command's indices ({name, value, highest}) and continuous
-- values ({name, value}) pass the engine's guards; else an error naming the
-- first that does not, and false (the engine ignores the command)
function Model:guarded(command, indices, values)
  for _, index in ipairs(indices) do
    if not whole(index[2], index[3]) then
      self:error(command .. " ignored: " .. index[1] .. " " .. tostring(index[2]) .. " is not a whole number from 0 to "
        .. index[3])
      return false
    end
  end
  for _, value in ipairs(values or {}) do
    if not finite(value[2]) then
      self:error(command .. " ignored: " .. value[1] .. " " .. tostring(value[2]) .. " is not a finite number")
      return false
    end
  end
  return true
end

-- A continuous value the engine clips: an error when Lua sent it outside the
-- range (the engine plays the clipped one, Lua believes the other)
function Model:clipped(command, name, value, range)
  if value < range[1] or value > range[2] then
    self:error(command .. ": " .. name .. " " .. tostring(value) .. " is clipped to " .. range[1] .. ".." .. range[2])
  end
  return math.min(range[2], math.max(range[1], value))
end

local RECEIVERS = {}

function RECEIVERS.setFastLfo(self, args)
  local lfo, voice, destination, shape = args[1], args[2], args[3], args[4]
  if not self:guarded("setFastLfo", { { "lfo", lfo, self.lfo_count - 1 }, { "voice", voice, self.voice_count - 1 },
    { "destination", destination, self.destinations - 1 }, { "shape", shape, self.shapes - 1 } },
    { { "rate", args[5] }, { "depth", args[6] }, { "offset", args[7] } }) then return end
  local node = { voice = voice, destination = destination, shape = shape,
    rate = self:clipped("setFastLfo", "rate", args[5], ENGINE.rate),
    depth = self:clipped("setFastLfo", "depth", args[6], ENGINE.depth),
    offset = self:clipped("setFastLfo", "offset", args[7], ENGINE.offset) }
  local running = self.lfos[lfo]
  if running then
    self.counts.lfo_replaced = self.counts.lfo_replaced + 1
    if running.voice ~= voice or running.destination ~= destination then self.counts.lfo_moved = self.counts.lfo_moved + 1 end
    if node.depth == 0 and running.depth > 0 then self.counts.lfo_at_zero = self.counts.lfo_at_zero + 1 end
  else
    self.counts.lfo_started = self.counts.lfo_started + 1
  end
  self.lfos[lfo] = node
end

function RECEIVERS.stopFastLfo(self, args)
  local lfo = args[1]
  if not self:guarded("stopFastLfo", { { "lfo", lfo, self.lfo_count - 1 } }) then return end
  if not self.lfos[lfo] then
    self:error("stopFastLfo " .. lfo .. ": no node runs (a no-op in the engine; Lua believed one did)")
    return
  end
  self.lfos[lfo] = nil
  self.counts.lfo_stopped = self.counts.lfo_stopped + 1
end

function RECEIVERS.syncFastLfo(self, args)
  local lfo = args[1]
  if not self:guarded("syncFastLfo", { { "lfo", lfo, self.lfo_count - 1 } }, { { "phase", args[2] } }) then return end
  if not self.lfos[lfo] then
    self:error("syncFastLfo " .. lfo .. ": no node runs (a no-op in the engine; Lua believed one did)")
    return
  end
  self.counts.lfo_synced = self.counts.lfo_synced + 1
end

function RECEIVERS.setFastOffset(self, args)
  local voice, slot, destination = args[1], args[2], args[3]
  if not self:guarded("setFastOffset", { { "voice", voice, self.voice_count - 1 }, { "noteSlot", slot, self.note_slots - 1 },
    { "destination", destination, self.destinations - 1 } }, { { "offset", args[4] } }) then return end
  -- the matrix sends its clamped sum, so a value past the range is Lua's fault
  self.offsets[voice][destination] = self:clipped("setFastOffset", "offset", args[4], ENGINE.offset)
  self.counts.offsets_sent = self.counts.offsets_sent + 1
end

local ROUTE_FIELDS = { "source", "voice", "destination", "depth", "attack", "decay", "sustain", "release", "curve", "loop" }
Model.ROUTE_FIELDS = ROUTE_FIELDS

function RECEIVERS.setFastEnv(self, args)
  local route = args[1]
  if not self:guarded("setFastEnv", { { "route", route, self.route_count - 1 }, { "source", args[2], self.voice_count - 1 },
    { "voice", args[3], self.voice_count - 1 }, { "destination", args[4], self.destinations - 1 }, { "loop", args[11], 1 } },
    { { "depth", args[5] }, { "attack", args[6] }, { "decay", args[7] }, { "sustain", args[8] }, { "release", args[9] },
      { "curve", args[10] } }) then return end
  local settings = { source = args[2], voice = args[3], destination = args[4], loop = args[11],
    depth = self:clipped("setFastEnv", "depth", args[5], ENGINE.env_depth),
    attack = self:clipped("setFastEnv", "attack", args[6], self.times),
    decay = self:clipped("setFastEnv", "decay", args[7], self.times),
    sustain = self:clipped("setFastEnv", "sustain", args[8], ENGINE.sustain),
    release = self:clipped("setFastEnv", "release", args[9], self.times),
    curve = self:clipped("setFastEnv", "curve", args[10], ENGINE.curve) }
  local running = self.routes[route]
  if running and (running.voice ~= settings.voice or running.destination ~= settings.destination) then
    self.counts.routes_moved = self.counts.routes_moved + 1
  end
  self.routes[route] = settings
  self.counts.routes_set = self.counts.routes_set + 1
end

function RECEIVERS.stopFastEnv(self, args)
  local route = args[1]
  if not self:guarded("stopFastEnv", { { "route", route, self.route_count - 1 } }) then return end
  if not self.routes[route] then
    self:error("stopFastEnv " .. route .. ": no route runs (a no-op in the engine; Lua believed one did)")
    return
  end
  self.routes[route] = nil
  self.counts.routes_stopped = self.counts.routes_stopped + 1
end

function RECEIVERS.setScatter(self, args)
  if not self:guarded("setScatter", { { "destinations", args[3], 2 ^ self.destinations - 1 },
    { "voices", args[4], 2 ^ self.voice_count - 1 } }, { { "depth", args[1] }, { "rate", args[2] } }) then return end
  self.scatter = { depth = self:clipped("setScatter", "depth", args[1], ENGINE.scatter_depth),
    rate = self:clipped("setScatter", "rate", args[2], ENGINE.scatter_rate), destinations = args[3], voices = args[4] }
  self.counts.scatter_sent = self.counts.scatter_sent + 1
end

-- Every call since the last feed (calls: the stub's context.engine_calls,
-- never cleared while the model reads it). A hit is stamped with the time of
-- the feed, which is never before the hit: an envelope looks younger here
-- than it is, so its end is seen late, never early
function Model:feed(calls)
  for index = self.read + 1, #calls do
    local entry = calls[index]
    local receive = RECEIVERS[entry.name]
    if receive then receive(self, entry.args) end
    if HITS[entry.name] then
      local voice = entry.args[1] + 1
      self.hits[voice] = util.time()
      self.ended[voice] = false
      self.counts.hits = self.counts.hits + 1
    end
  end
  self.read = #calls
end

---------------------------------------------------------------------------
-- What the params imply
---------------------------------------------------------------------------

local function lfo_id(n, field) return "strata_lfo" .. n .. (field and ("_" .. field) or "") end

-- A key that waits to be sent: due in the LFOs' round robin (its queue, an
-- upvalue of mark_due) or waiting in the send budget (its record, an
-- upvalue of expected_value). Read from the modules' locals, as the tests
-- read the round robin, never written
local function upvalue(fn, name)
  local index = 1
  while true do
    local found, value = debug.getupvalue(fn, index)
    if not found then return nil end
    if found == name then return value end
    index = index + 1
  end
end

function Model.waiting(S, key)
  local queue = upvalue(S.lib.lfos.mark_due, "queue")
  local budget = upvalue(S.lib.engine_sync.expected_value, "budget")
  return (queue ~= nil and queue.due[key] ~= nil) or (budget ~= nil and budget.pending[key] ~= nil)
end

-- Whether anything waits in the round robin or the budget
function Model.anything_waiting(S)
  local queue = upvalue(S.lib.lfos.mark_due, "queue")
  local budget = upvalue(S.lib.engine_sync.expected_value, "budget")
  return (queue ~= nil and next(queue.due) ~= nil) or (budget ~= nil and #budget.order > 0)
end

-- LFO n's rate and depth as its params give them (design 3.4 §2.4): the
-- rate param (free) or its division at the tempo (clocked), times 4 ^
-- (amount x s), between the engine's bounds; the depth param times 1 +
-- amount x s, between 0 and 100; s the shape value of the lower LFO its
-- input names (0 for none: the source's value, Lua's as every source is,
-- is 0 while it is off)
local function input_value(S, n, input)
  local option = params:get(lfo_id(n, input))
  if option <= 1 then return 0 end
  return S.lib.lfos.value(option - 1)
end

local function lfo_want(S, n)
  local LFO = S.lib.lfos.LFO
  local rate
  if params:get(lfo_id(n, "mode")) == 2 then
    rate = 1 / (LFO.division_values[params:get(lfo_id(n, "division"))] * LFO.beats_per_division
      * S.lib.params_setup.beat_seconds_now())
  else
    rate = params:get(lfo_id(n, "rate"))
  end
  rate = rate * 4 ^ (params:get(lfo_id(n, "rate_mod_amt")) / 100 * input_value(S, n, "rate_mod"))
  rate = math.min(LFO.engine_max_hz, math.max(LFO.min_hz, rate))
  local depth = params:get(lfo_id(n, "depth"))
    * (1 + params:get(lfo_id(n, "depth_mod_amt")) / 100 * input_value(S, n, "depth_mod"))
  depth = math.min(100, math.max(0, depth))
  -- at a depth param of 0 the node plays nothing: offset 0 too (#925, fix
  -- round 1: as a Lua home's home_m and 3.8.0's stopped node)
  local offset = 0
  if params:get(lfo_id(n, "depth")) > 0 then
    offset = math.min(ENGINE.offset[2], math.max(ENGINE.offset[1], 2 * params:get(lfo_id(n, "offset")) / 100))
  end
  return { shape = params:get(lfo_id(n, "shape")) - 1, rate = rate, depth = depth / 100, offset = offset }
end

-- The (voice, destination) of LFO n's node as its params imply it: on, its
-- home a fast destination's fixed param, at any depth (#925: an on LFO
-- with a fast home has a node, which plays nothing at depth 0: offset 0 too);
-- else nil
local function lfo_place(S, n)
  if params:get(lfo_id(n)) ~= 1 then return nil end
  return S.lib.lfos.fast_destination(S.lib.matrix.home(n) or "")
end

-- The param a routing's or home's destination id moves now: v<i>_main
-- through main_param_id (it follows the voice's source), an existing
-- param itself; nil for "" or an id with no param
local function resolve(id)
  if type(id) ~= "string" or id == "" then return nil end
  local voice = id:match("^v(%d+)_main$")
  if voice then id = main_param_id(tonumber(voice)) end
  if not params.lookup[id] then return nil end
  return id
end

-- Routing k's resolved param and depth while the params play it: on, a
-- known source, a destination the matrix offers, a depth other than 0
local function routing_plays(S, k)
  if params:get("matrix_" .. k) ~= 1 then return nil end
  local depth, routing = params:get("matrix_" .. k .. "_depth"), S.matrix[k]
  if depth == 0 or not S.lib.mod_sources.get(routing.source) then return nil end
  local known = false
  for _, id in ipairs(S.lib.matrix.destination_ids()) do
    if id == routing.dest then known = true; break end
  end
  if not known then return nil end
  local id = resolve(routing.dest)
  if not id then return nil end
  return id, depth
end

local function envelope_voice(source)
  return tonumber(type(source) == "string" and source:match("^env(%d+)$") or nil)
end

-- Every channel's sum, by "<voice> <destination>": the playing routings to
-- a fast param but those an envelope plays in the engine (its route), and
-- each playing home whose param is fast but not its own (a v<i>_main on a
-- buffer voice's position, ruling 16), each m = depth / 100 x the source's
-- normalized value or the home's m (Lua's LFO value: the sources are
-- Lua's), clamped to the engine's range
local function channel_sums(S)
  local sums = {}
  local function add(id, m)
    local voice, destination = S.lib.lfos.fast_destination(id)
    if not voice or m == 0 or not finite(m) then return end
    local key = voice .. " " .. destination
    sums[key] = (sums[key] or 0) + m
  end
  for k = 1, S.constants.MATRIX_SLOTS do
    local id, depth = routing_plays(S, k)
    if id and not envelope_voice(S.matrix[k].source) then
      add(id, depth / 100 * S.lib.mod_sources.normalized(S.matrix[k].source))
    end
  end
  for n = 1, S.constants.NUM_LFOS do
    local key = S.lib.matrix.home(n)
    if params:get(lfo_id(n)) == 1 and params:get(lfo_id(n, "depth")) > 0 and not S.lib.lfos.fast_destination(key)
      and S.lib.matrix.home_known(key) then
      local id = resolve(key)
      if id then add(id, S.lib.lfos.home_m(n) or 0) end
    end
  end
  return sums
end

-- The params the sources in `moved` (a set of source keys) reach now: each
-- playing routing's from one of them, and each playing home of an LFO
-- among them (lfo<n>) whose param is not its own (a Lua home, a v<i>_main;
-- a fast home is its node, a macro its own hand-over), resolved. A set of
-- param ids: what a moved source may send in a step that has nothing else
-- to do
function Model.reached_ids(S, moved)
  local ids = {}
  for k = 1, S.constants.MATRIX_SLOTS do
    local id = routing_plays(S, k)
    if id and moved[S.matrix[k].source] then ids[id] = true end
  end
  for n = 1, S.constants.NUM_LFOS do
    local key = S.lib.matrix.home(n)
    if moved["lfo" .. n] and params:get(lfo_id(n)) == 1 and params:get(lfo_id(n, "depth")) > 0
      and not S.lib.lfos.fast_destination(key) and not tostring(key):match("^macro_%d+$")
      and S.lib.matrix.home_known(key) then
      local id = resolve(key)
      if id then ids[id] = true end
    end
  end
  return ids
end

-- Route k as the params imply it: a playing routing from env<v> to a fast
-- param carries the source voice's six envelope params; else nil
local function route_want(S, k)
  local source = envelope_voice(S.matrix[k].source)
  if not source or source < 1 or source > S.constants.NUM_VOICES then return nil end
  local id, depth = routing_plays(S, k)
  local voice, destination = S.lib.lfos.fast_destination(id or "")
  if not voice then return nil end
  local function env(key) return params:get("v" .. source .. "_env_" .. key) end
  return { source = source - 1, voice = voice - 1, destination = destination, depth = depth / 100,
    attack = env("attack"), decay = env("decay"), sustain = env("sustain"), release = env("release"),
    curve = env("curve"), loop = env("loop") == 2 and 1 or 0 }
end
Model.route_want = route_want

---------------------------------------------------------------------------
-- The comparison
---------------------------------------------------------------------------

local function near(a, b, tolerance) return math.abs(a - b) <= tolerance + ENGINE.ulp * math.max(1, math.abs(b)) end

-- One difference: allowed when allow names it (counted under that name),
-- else a problem
function Model:differ(problems, allow, name, text)
  if allow and name and allow[name] then
    self.allowed[name] = (self.allowed[name] or 0) + 1
    return
  end
  problems[#problems + 1] = text
end

-- The LFOs: an on LFO with a fast home (lfo_place, at any depth) has a
-- node with its settings (the rate within LFO.engine_rate_threshold, the
-- depth and offset within LFO.send_threshold: what Lua resends past), and
-- no other LFO has one
function Model:compare_lfos(S, problems, allow)
  local LFO = S.lib.lfos.LFO
  for n = 1, self.lfo_count do
    local voice, destination = lfo_place(S, n)
    local node, key = self.lfos[n - 1], "lfo" .. n .. " engine"
    local waiting = Model.waiting(S, key) and "waiting" or nil
    if voice and not node then
      self:differ(problems, allow, waiting, "LFO " .. n .. ": the params play it on voice " .. voice .. "'s destination "
        .. destination .. ", but the engine has no node")
    elseif not voice and node then
      self:differ(problems, allow, waiting, "LFO " .. n .. ": a node on voice " .. (node.voice + 1)
        .. " the params do not play")
    elseif node then
      local want = lfo_want(S, n)
      local function field(name, ok, have, wanted)
        if not ok then
          self:differ(problems, allow, waiting, "LFO " .. n .. ": " .. name .. " " .. tostring(have) .. " in the engine, "
            .. tostring(wanted) .. " by the params")
        end
      end
      field("voice", node.voice == voice - 1, node.voice + 1, voice)
      field("destination", node.destination == destination, node.destination, destination)
      field("shape", node.shape == want.shape, node.shape, want.shape)
      field("rate", near(node.rate, want.rate, want.rate * LFO.engine_rate_threshold), node.rate, want.rate)
      field("depth", near(node.depth, want.depth, LFO.send_threshold), node.depth, want.depth)
      field("offset", near(node.offset, want.offset, LFO.send_threshold), node.offset, want.offset)
    end
  end
end

-- The channels: each one's offset is the matrix's sum the params imply
-- (within LFO.send_threshold, what the matrix resends past)
function Model:compare_offsets(S, problems, allow)
  local sums, threshold = channel_sums(S), S.lib.lfos.LFO.send_threshold
  for voice = 1, self.voice_count do
    for destination = 0, self.destinations - 1 do
      local want = math.min(ENGINE.offset[2], math.max(ENGINE.offset[1], sums[voice .. " " .. destination] or 0))
      local have = self.offsets[voice - 1][destination]
      if math.abs(want - have) >= threshold then
        local key = "matrix fast " .. voice .. " " .. destination
        self:differ(problems, allow, Model.waiting(S, key) and "waiting" or nil, "voice " .. voice .. "'s channel "
          .. destination .. ": offset " .. have .. " in the engine, " .. want .. " by the routings")
      end
    end
  end
end

-- The routes: each one carries what its routing and its source voice's
-- envelope params give, or nothing
function Model:compare_routes(S, problems, allow)
  for k = 1, self.route_count do
    local want, have = route_want(S, k), self.routes[k - 1]
    local waiting = Model.waiting(S, "env route " .. k) and "waiting" or nil
    if want and not have then
      self:differ(problems, allow, waiting, "route " .. k .. ": the routing plays it, but the engine has no route")
    elseif have and not want then
      self:differ(problems, allow, waiting, "route " .. k .. ": a route the routing does not play")
    elseif want then
      for _, name in ipairs(ROUTE_FIELDS) do
        if not near(have[name], want[name], 0) then
          self:differ(problems, allow, waiting, "route " .. k .. ": " .. name .. " " .. tostring(have[name])
            .. " in the engine, " .. tostring(want[name]) .. " by the params")
        end
      end
    end
  end
end

-- Scatter: the state its params and the locks give (depth 0 while off);
-- never sent is the engine's own start, no node
function Model:compare_scatter(S, problems)
  local depth = params:get("scatter") == 1 and params:get("scatter_depth") / 100 or 0
  local have = self.scatter
  if not have then
    if depth > 0 then problems[#problems + 1] = "scatter: on at depth " .. depth .. ", but never sent" end
    return
  end
  local destinations, voices, bit_value = 0, 0, 1
  for _, record in ipairs(S.lib.scatter.SCATTER.destinations) do
    if params:get(record.id) == 1 then destinations = destinations + bit_value end
    bit_value = bit_value * 2
  end
  bit_value = 1
  for voice = 1, self.voice_count do
    if not S.locked[voice] then voices = voices + bit_value end
    bit_value = bit_value * 2
  end
  if not (near(have.depth, depth, 0) and near(have.rate, params:get("scatter_rate"), 0)
    and have.destinations == destinations and have.voices == voices) then
    problems[#problems + 1] = string.format("scatter: %g %g %d %d in the engine, %g %g %d %d by the params", have.depth,
      have.rate, have.destinations, have.voices, depth, params:get("scatter_rate"), destinations, voices)
  end
end

-- The envelopes as the engine runs them (docs/notes/engine/envelopes.md,
-- \strataEnvelope): with the loop off, one that has ended stays ended until
-- the next hit, whatever its times are set to since (an EnvGen reads a
-- segment's time as the segment starts). Seen ended once the time since its
-- hit (as the feed stamped it) passed its run at the settings of that moment
-- (attack, decay and, with a sustain, the release: a voice that is not
-- gated holds 0), then Lua's model (S.lib.envelopes.value) must read 0 until
-- the next hit; a loop turned on starts it again, so its end is not judged
-- until the next hit. allow.ended_runs_again is #969
function Model:compare_envelopes(S, problems, allow)
  local now = util.time()
  for voice = 1, self.voice_count do
    local function env(key) return params:get("v" .. voice .. "_env_" .. key) end
    if env("loop") == 2 then
      self.hits[voice], self.ended[voice] = nil, false
    elseif self.hits[voice] then
      local run = env("attack") + env("decay") + (env("sustain") > 0 and env("release") or 0)
      if not self.ended[voice] and now - self.hits[voice] >= run then
        self.ended[voice], self.ended_runs[voice] = true, run
        self.counts.envelopes_ended = self.counts.envelopes_ended + 1
      end
      if self.ended[voice] and S.lib.envelopes.value(voice) > 0 then
        -- Lua's own record of the hit, for the line only (upvalue of value)
        local lua_hit = (upvalue(S.lib.envelopes.value, "hits") or {})[voice]
        -- #969's case only: a time raised since the end was seen, so the run
        -- now outlasts the time since the hit; any other level above 0 is
        -- a problem whatever allow says
        local raised = run > self.ended_runs[voice] and run > now - self.hits[voice]
        self:differ(problems, raised and allow, "ended_runs_again", string.format("voice %d's envelope ended and runs again (%g)"
          .. " with no hit since (%s): hit at %.3f s (Lua's at %s), now %.3f s, a run of %.3f s now (%.3f s when it ended)",
          voice, S.lib.envelopes.value(voice), raised and "#969" or "no time raised: not #969", self.hits[voice],
          lua_hit and string.format("%.3f s", lua_hit.time) or "none", now, run, self.ended_runs[voice]))
      end
    end
  end
end

-- Every difference between the engine (as fed) and what the params imply,
-- and every error the feed met; allow (optional) names the differences
-- allowed: waiting (a send due in the round robin or the budget),
-- ended_runs_again (#969)
function Model:compare(S, allow)
  local problems = {}
  for _, text in ipairs(self.errors) do problems[#problems + 1] = "the engine ignored or changed: " .. text end
  self.errors = {}
  self:compare_lfos(S, problems, allow)
  self:compare_offsets(S, problems, allow)
  self:compare_routes(S, problems, allow)
  self:compare_scatter(S, problems)
  self:compare_envelopes(S, problems, allow)
  return problems
end

return Model

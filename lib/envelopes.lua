-- lib/envelopes.lua
-- The envelopes (3.7, design §7, decision 4), S.lib.envelopes: one
-- envelope per voice (attack to 1, decay to the sustain, the hit's hold,
-- release to 0, each slope bent by the curve; loop starts it again when it
-- ends), fired by its own voice's hits, a unipolar modulation source
-- (env1..env7, section envelopes, EN1..EN7, 0..1) with its six params as
-- settings rows. Lua models it (shape, value: a voice_hit hook keeps each
-- voice's last hit), which the matrix reads for its Lua destinations and
-- MOD draws. A playing matrix routing from an envelope to a fast
-- destination is the engine's (owns): the matrix leaves it out of its sum,
-- and each 48 Hz step (S.lib.lfos.on_step) brings the engine's route for
-- that slot to it through the LFOs' round robin and the send budget:
-- setFastEnv when its settings differ from what the engine has or will
-- have, stopFastEnv when the slot stops being owned. Only this module
-- calls those two commands. Params: the voice-param record envelopes
-- (v<i>_env_attack, _decay, _sustain, _release, _curve, _loop; scene
-- fields, the loop discrete). Nothing here sends from a hook, yields or
-- redraws. See docs/notes/lua/envelopes.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local ENVELOPES = S.constants.ENVELOPES
  M.ENVELOPES = ENVELOPES

  -- The six params' keys (v<i>_<key>) and defaults (design §7.2), the
  -- curve's range, the loop's options, the curve under which a slope is
  -- worked out as a line, the section and the round robin's key per route
  local ENV = {
    keys = {"env_attack", "env_decay", "env_sustain", "env_release", "env_curve", "env_loop"},
    labels = {"attack", "decay", "sustain", "release", "curve", "loop"},
    defaults = {env_attack = 0.005, env_decay = 0.2, env_sustain = 0, env_release = 0.2, env_curve = -4, env_loop = 1},
    curve_range = {-8, 8},
    loop_options = {"off", "on"},
    loop_on = 2,
    linear_below = 1e-6,
    ms_below = 0.9995,     -- s: a time shown in ms below it, in s from it
    section = "envelopes",
    route_prefix = "env route ",
  }

  local function valid(voice_idx)
    return type(voice_idx) == "number" and voice_idx % 1 == 0 and voice_idx >= 1 and voice_idx <= NUM_VOICES
  end
  local function is_route(k)
    return type(k) == "number" and k % 1 == 0 and k >= 1 and k <= ENVELOPES.routes
  end

  -- Voice v's settings now, {attack, decay, sustain, release, curve, loop},
  -- in one table per voice filled again at each call (read at once, never
  -- kept: the 48 Hz step and MOD's draws make none)
  local settings_of = {}
  for voice_idx = 1, NUM_VOICES do settings_of[voice_idx] = {} end
  local function setting(values, key)
    local value = values[key]
    if value == nil then return ENV.defaults[key] end
    return value
  end
  local function settings(voice_idx)
    local values, set = S.voices[voice_idx].values, settings_of[voice_idx]
    set.attack, set.decay = setting(values, "env_attack"), setting(values, "env_decay")
    set.sustain, set.release = setting(values, "env_sustain"), setting(values, "env_release")
    set.curve, set.loop = setting(values, "env_curve"), setting(values, "env_loop") == ENV.loop_on
    return set
  end

  ---------------------------------------------------------------------------
  -- The shape (\strataEnvelope's, design §7.1)
  ---------------------------------------------------------------------------

  -- A slope from `from` to `to` over T s, t s in: from + (to - from) x
  -- (1 - exp(curve t / T)) / (1 - exp(curve)), a line at curve 0
  local function slope(from, to, t, T, curve)
    if T <= 0 then return to end
    local x = util.clamp(t / T, 0, 1)
    if math.abs(curve) < ENV.linear_below then return from + (to - from) * x end
    return from + (to - from) * (1 - math.exp(curve * x)) / (1 - math.exp(curve))
  end

  -- EnvGen takes a segment's destination, duration and curve when entering
  -- it. Edits during the segment take effect at the next boundary (#1233).
  local function latch(hit, segment, start, target, duration, curve)
    hit.segment, hit.started = segment, start
    hit.from, hit.target, hit.duration, hit.curve = hit.target, target, duration, curve
  end

  local function start_hit(set, now, from, hold)
    local hit = {target = from, hold = hold, time = now}
    latch(hit, "attack", now, 1, set.attack, set.curve)
    return hit
  end

  local function advance(hit, set, now)
    while not hit.ended do
      local boundary = hit.started + hit.duration
      if now < boundary then
        return slope(hit.from, hit.target, now - hit.started, hit.duration, hit.curve)
      end
      if hit.segment == "attack" then
        latch(hit, "decay", boundary, set.sustain, set.decay, set.curve)
      elseif hit.segment == "decay" then
        latch(hit, "hold", boundary, set.sustain, set.sustain > 0 and hit.hold or 0, set.curve)
      elseif hit.segment == "hold" then
        latch(hit, "release", boundary, 0, set.sustain > 0 and set.release or 0, set.curve)
      elseif set.loop then
        -- Every edit advances the old settings first. Whole cycles after
        -- this boundary therefore share one shape, even after a long sleep.
        local cycle = set.attack + set.decay + (set.sustain > 0 and (hit.hold + set.release) or 0)
        if cycle <= 0 then hit.ended = true; return 0 end
        hit.time = boundary + math.floor((now - boundary) / cycle) * cycle
        latch(hit, "attack", hit.time, 1, set.attack, set.curve)
      else
        hit.ended = true
      end
    end
    return 0
  end

  -- Pure shape for a run whose settings stay fixed. The live model moves
  -- the same segments forward in place and allocates nothing on a step.
  function M.shape(set, elapsed, hold, from)
    return advance(start_hit(set, 0, from or 0, math.max(hold or 0, 0)), set, math.max(elapsed or 0, 0))
  end

  local hits = {}

  function M.value(voice_idx)
    if not valid(voice_idx) then return 0 end
    local hit = hits[voice_idx]
    if not hit or hit.ended then return 0 end
    return util.clamp(advance(hit, settings(voice_idx), util.time()), 0, 1)
  end

  -- A hit's hold: its gate length when the caller knows it (a gated
  -- step's), else a gated voice's gate length, else 0. Gated is the gate
  -- rule's answer (3.9: a gate voice, or a pulse voice with a step while
  -- the patterns play), as the engine's hold reads seqGate
  local function hold_for(voice_idx, info)
    if info and type(info.gate_seconds) == "number" then return info.gate_seconds end
    local sequencer = S.lib.sequencer
    if sequencer.gate_wanted(voice_idx) == 1 then
      return sequencer.gate_seconds(voice_idx) or 0
    end
    return 0
  end

  -- Every hit of a voice (lib/engine_sync.lua's voice_hit: a start, a
  -- retrigger, a played extra note's start; a chord step is one)
  S.register_voice_hit({name = "envelopes", hit = function(voice_idx, info)
    if not valid(voice_idx) then return end
    local from = M.value(voice_idx)
    hits[voice_idx] = start_hit(settings(voice_idx), util.time(), from, hold_for(voice_idx, info))
  end})

  -- When loop turns off, the current cycle simply finishes. Turning it on
  -- starts an idle envelope from zero, or repeats the current run at its end.
  local function loop_changed(voice_idx, on)
    local hit = hits[voice_idx]
    if on and (not hit or hit.ended) then
      hits[voice_idx] = start_hit(settings(voice_idx), util.time(), 0, 0)
    end
  end

  ---------------------------------------------------------------------------
  -- The engine's routes (design §7.3)
  ---------------------------------------------------------------------------

  -- The voice whose envelope routing k's source is (env<v>), else nil
  -- (S.lib.matrix.status reads it: such a routing to a fast destination is
  -- the envelopes')
  local function source_voice(k)
    local source = S.matrix[k] and S.matrix[k].source
    local voice_idx = type(source) == "string" and tonumber(source:match("^env(%d+)$"))
    if valid(voice_idx) then return voice_idx end
    return nil
  end
  M.source_voice = source_voice

  -- What route k carries while its routing is the envelopes' (playing,
  -- from env<v>, to a fast destination), filled into the route's own
  -- table (one per route, made once: a step builds none), else nil
  local wants = {}
  for k = 1, ENVELOPES.routes do wants[k] = {} end
  local function route_want(k)
    local voice_from = source_voice(k)
    if not voice_from then return nil end
    local id, depth = S.lib.matrix.playing(k)
    if not id then return nil end
    local voice_idx, destination = S.lib.lfos.fast_destination(id)
    if not voice_idx then return nil end
    local set, want = settings(voice_from), wants[k]
    want.source, want.voice, want.destination, want.depth = voice_from, voice_idx, destination, depth / 100
    want.attack, want.decay, want.sustain, want.release = set.attack, set.decay, set.sustain, set.release
    want.curve, want.loop = set.curve, set.loop and 1 or 0
    return want
  end

  -- Whether matrix routing k is the engine's: a playing routing from an
  -- envelope to a fast destination, the matrix's one answer
  -- (S.lib.matrix.status(k) "owned", #926)
  function M.owns(k)
    return is_route(k) and S.lib.matrix.status(k) == "owned"
  end

  local ROUTE_FIELDS = {"source", "voice", "destination", "depth", "attack", "decay", "sustain", "release", "curve",
    "loop"}
  local function same(want, had)
    if type(had) ~= "table" then return false end
    for _, field in ipairs(ROUTE_FIELDS) do
      if want[field] ~= had[field] then return false end
    end
    return true
  end

  -- The table handed to the budget is a copy: the route's own is filled
  -- again at the next step, and the budget's answer must keep what was sent
  local function copy(want)
    local handed = {}
    for _, field in ipairs(ROUTE_FIELDS) do handed[field] = want[field] end
    return handed
  end

  -- Each route is one deferrable id of the send budget (no param id holds
  -- a space): its engine sender sends setFastEnv for the settings it is
  -- given, or stopFastEnv for false; what the engine has or will have is
  -- the budget's own answer (expected_value). The round robin's send, made
  -- once per route, reads the routing when it runs (a send that waited is
  -- never an older one) and hands it on only when it differs
  local route_keys, route_sends = {}, {}
  local function expected(k) return S.lib.engine_sync.expected_value(route_keys[k]) end
  for k = 1, ENVELOPES.routes do
    local key = ENV.route_prefix .. k
    route_keys[k] = key
    S.engine_senders[key] = function(want)
      if want then
        engine.setFastEnv(k - 1, want.source - 1, want.voice - 1, want.destination, want.depth, want.attack,
          want.decay, want.sustain, want.release, want.curve, want.loop)
      else
        engine.stopFastEnv(k - 1)
      end
    end
    route_sends[k] = function()
      local want, had = route_want(k), expected(k)
      if want == nil and not had then return end
      if want ~= nil and same(want, had) then return end
      S.lib.engine_sync.send_engine_value(key, want and copy(want) or false)
    end
  end

  local function mark(k) S.lib.lfos.mark_due(route_keys[k], route_sends[k]) end

  -- Route k against its routing: marked when what it should carry differs
  -- from what the engine has or will have, or it should stop
  local function reconcile(k)
    local had = expected(k)
    if not had and not source_voice(k) then return end
    local want = route_want(k)
    if (want and not same(want, had)) or (not want and had) then mark(k) end
  end

  local step_errors, step_labels = {}, {}
  for k = 1, ENVELOPES.routes do step_labels[k] = "envelope route " .. k end
  S.lib.lfos.on_step(function()
    for k = 1, ENVELOPES.routes do
      S.lib.ui_frame.contained_call(step_errors, k, step_labels[k], reconcile, k)
    end
  end)

  -- A voice's param changed: each route it fires is marked
  local function mark_routes_of(voice_idx)
    for k = 1, ENVELOPES.routes do
      if source_voice(k) == voice_idx and route_want(k) then mark(k) end
    end
  end

  ---------------------------------------------------------------------------
  -- Params
  ---------------------------------------------------------------------------

  -- A time in whole ms, as it is shown below a second (the exp map stores
  -- 0.05 as 0.04999...: compared unrounded, a time shown as 50ms could be
  -- marked as under 50 ms)
  local function shown_ms(seconds) return math.floor(seconds * 1000 + 0.5) end

  -- A time as MOD and the menu show it: 5ms, 200ms, 1.5s, 10s
  local function time_text(seconds)
    if seconds < ENV.ms_below then return string.format("%dms", shown_ms(seconds)) end
    return (string.format("%.1f", seconds):gsub("%.0$", "")) .. "s"
  end

  local function time_param(name, default)
    return {type = "control", name = name,
      controlspec = controlspec.new(ENVELOPES.time_min, ENVELOPES.time_max, "exp", 0, default, "s"),
      formatter = function(param) return time_text(param:get()) end}
  end

  local record
  record = {
    name = "envelopes",
    count = #ENV.keys,
    add = function(voice_idx)
      local add = S.lib.params_setup.add_voice_param
      local function changed() mark_routes_of(voice_idx) end
      local params_by_key = {
        env_attack = time_param("env attack", ENV.defaults.env_attack),
        env_decay = time_param("env decay", ENV.defaults.env_decay),
        env_sustain = {type = "control", name = "env sustain",
          controlspec = controlspec.new(0, 1, "lin", 0, ENV.defaults.env_sustain),
          formatter = function(param) return string.format("%.2f", param:get()) end},
        env_release = time_param("env release", ENV.defaults.env_release),
        env_curve = {type = "control", name = "env curve",
          controlspec = controlspec.new(ENV.curve_range[1], ENV.curve_range[2], "lin", 0, ENV.defaults.env_curve),
          formatter = function(param) return string.format("%.1f", param:get()) end},
        env_loop = {type = "option", name = "env loop", options = ENV.loop_options, default = ENV.defaults.env_loop},
      }
      for _, key in ipairs(ENV.keys) do
        local param = params_by_key[key]
        param.action = function(value)
          if key == "env_loop" then loop_changed(voice_idx, value == ENV.loop_on) end
          changed()
        end
        add(voice_idx, record, key, param)
        -- Cross any elapsed boundaries with the settings in force then,
        -- before add_voice_param stores the edit (#969, #1233).
        local added = params:lookup_param("v" .. voice_idx .. "_" .. key)
        local store = added.action
        added.action = function(value)
          M.value(voice_idx)
          store(value)
        end
      end
    end,
    scene_defaults = ENV.defaults,
    discrete = {env_loop = {1, #ENV.loop_options}},
    scene_ranges = {env_attack = {ENVELOPES.time_min, ENVELOPES.time_max},
      env_decay = {ENVELOPES.time_min, ENVELOPES.time_max}, env_sustain = {0, 1},
      env_release = {ENVELOPES.time_min, ENVELOPES.time_max}, env_curve = {ENV.curve_range[1], ENV.curve_range[2]}},
    fader = false,
  }
  S.register_voice_params(record)

  ---------------------------------------------------------------------------
  -- The modulation sources and their settings rows
  ---------------------------------------------------------------------------

  -- Whether voice v's envelope reaches a Lua destination through a playing
  -- routing (where the model, stepped at 48 Hz, plays it)
  local function routed_to_lua(voice_idx)
    for k = 1, ENVELOPES.routes do
      if source_voice(k) == voice_idx then
        local id = S.lib.matrix.playing(k)
        if id and not S.lib.lfos.fast_destination(id) then return true end
      end
    end
    return false
  end

  local function describe(voice_idx)
    local set = settings(voice_idx)
    local under = shown_ms(ENVELOPES.approximate_under)
    local fast = shown_ms(set.attack) < under or shown_ms(set.decay) < under
    local mark_text = (fast and routed_to_lua(voice_idx)) and "~" or ""
    return mark_text .. time_text(set.attack) .. " " .. time_text(set.decay)
  end

  local function rows_for(voice_idx)
    local rows = {}
    for index, key in ipairs(ENV.keys) do
      local id = "v" .. voice_idx .. "_" .. key
      local function turn(d) enc_param_delta(3, id, d) end
      -- a control row turns finely under ALT (enc_param_delta reads it):
      -- its fine_enc says so, for MOD's ALT hint; the loop, an option, has none
      rows[index] = {label = ENV.labels[index], value = function() return tostring(params:string(id)) end,
        enc = turn, fine_enc = key ~= "env_loop" and turn or nil}
    end
    return rows
  end

  for voice_idx = 1, NUM_VOICES do
    S.register_mod_source({
      key = "env" .. voice_idx,
      name = "EN" .. voice_idx,
      section = ENV.section,
      range = {0, 1},
      value = function() return M.value(voice_idx) end,
      describe = function() return describe(voice_idx) end,
      fields = rows_for(voice_idx),
    })
  end

  return M
end

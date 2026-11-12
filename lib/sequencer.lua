-- lib/sequencer.lua
-- The pattern sequencer: S.patterns (the step levels) and S.pattern_steps
-- (the step attributes), both built fresh by the constructor; one clock per
-- voice (S.pattern_clocks, each at its own length, division and swing)
-- beside the transport's (S.pattern_clock, counting 16ths and bars:
-- S.pattern_position, S.pattern_sounding_step); S.pattern_playing; pattern
-- edits (every whole-pattern change through M.replace_pattern); the
-- sounding steps and the step LED levels. A step plays only through the
-- registered step outputs (S.register_step_output), Strata's own voices
-- first: they retrigger running voices and never create nodes. Step locks
-- and notes are base overrides (lib/engine_sync.lua). Also the per-voice
-- seq params (a registered voice-param record), the strata_seq group (the
-- chain, the division reset, following the transport), the steps scene
-- block, Euclidean fill and the chain. The patterns follow an external
-- clock's transport (clock.transport.start and stop, installed by a start
-- step). The functions that were global stay global. See
-- docs/notes/lua/sequencer.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local NUM_BOOKMARKS = S.constants.NUM_BOOKMARKS
  local NUM_SCENES = S.constants.NUM_SCENES
  -- A random step's lowest level: half the top level, rounded up (8 of 15)
  local RANDOM_STEP_FLOOR = math.ceil(MAX_STEP_LEVEL / 2)
  local er = require "er"

  -- The sequencer's tunables (design 8.1-8.13), in one table
  local SEQ = {
    max_step_notes = 8,              -- a step's chord: 1-8 scale degrees
    min_ratchet_seconds = 0.02,      -- hits never closer than 20 ms
    max_ratchet = 4,
    max_prob = 100,                  -- percent; nil plays always
    max_degree = 14,                 -- notes: -14..14 scale degrees
    division_names = {"1/32", "1/16t", "1/16", "1/8t", "1/8", "1/4", "1/2", "1 bar"},
    division_beats = {1/8, 1/6, 1/4, 1/3, 1/2, 1, 2, 4},
    default_division = 3,            -- 1/16
    gate_options = {"off", "on"},    -- v<i>_seq_gate: seqGate is the index - 1
    gate_on = 2,
    gate_steps = {0.05, 16},         -- a gate's length in steps (the voice's and a step's)
    gate_length_default = 0.5,
    gate_release = {0.005, 4},       -- s
    gate_release_default = 0.1,
    gate_seconds = {0.005, 120},     -- what gateSeconds may carry
    swing = {50, 75},                -- percent: 50 straight
    group_params = 6,                -- strata_seq's own (the quantizer adds PARAM_COUNT)
    max_chain_bars = 16,
    chain_defaults = {from = 1, scenes = 2, bars = 4},
    transport_beats = 1 / 4,         -- the transport counts 16ths
    bar_beats = 4,
    past_length_level = 1,           -- a set step past the voice's length, on the grids
    playing_level = 15, playing_empty_level = 4,
    lock_params = {pos = "buf_pos", pitch = "grain_pitch", size = "grain_size"},
    lock_keys = {"pos", "pitch", "size", "bookmark"},
    semitones = 12, a4_note = 69, a4_freq = 440,
    chromatic_mask = 4095,           -- every pitch class (lib/variation.lua's scale_mask, the scale off)
    tone_tolerance = 0.01,           -- semitones: a pitch this near a tone is on it
    beat_tolerance = 1e-9,           -- beats: two beats this near are one
    loop_tolerance = 1e-6,           -- as lib/positions.lua's jump: inside the loop
  }
  M.SEQ = SEQ

  -- Pattern sequencer
  S.patterns = {}
  S.pattern_steps = {}           -- [voice][step]: nil, or the step's attributes
  S.pattern_position = 1         -- the next 16th the transport plays
  S.pattern_sounding_step = nil  -- the 16th it played last (nil before the first)
  S.pattern_playing = false
  S.pattern_clock = nil          -- the transport's clock
  S.pattern_clocks = {}          -- [voice]: the voice's clock, while the patterns play
  S.pattern_sounding_steps = {}  -- [voice]: the step its clock played last (nil before the first)
  S.seq_euclid = {}              -- [voice]: {hits, rotation} of the last fill (not stored)

  -- Initialize patterns for each voice
  for i = 1, NUM_VOICES do
    S.patterns[i] = {}
    S.pattern_steps[i] = {}
    for step = 1, PATTERN_LENGTH do
      S.patterns[i][step] = 0  -- 0=off, 1-15=velocity/brightness
    end
  end

  -- The playing state (local; read through the functions below): per voice
  -- {anchor, tick, beat, due, position, pass_length} and the
  -- transport's {anchor, tick, beat, due}. A participant's beats are its own
  -- (the beat of its tick 0, of the step it played last, of the step it
  -- waits for), never read back from the clock, so a transport reset that
  -- is not followed moves none of them apart. play.failed: the outputs
  -- skipped until the next start; play.started: a voice started since the
  -- last redraw; play.reset_beat: a division reset's bar; overrides: per
  -- voice, the param ids its last played step overrides; last_played: per
  -- voice, that step; gate_sent: per voice, the gateSeconds sent last
  local play = {voices = {}, transport = {}, failed = {}, started = false, reset_beat = nil}
  local overrides, last_played, gate_sent = {}, {}, {}
  -- the chain: the scene loaded last and the beat of the next link
  local chain = {current = nil, next_beat = nil}

  local function whole_between(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
  end

  local function number_between(value, low, high)
    return type(value) == "number" and value == value and value >= low and value <= high
  end

  local function valid_voice(voice_idx) return whole_between(voice_idx, 1, NUM_VOICES) end

  local function near(a, b) return math.abs(a - b) <= SEQ.beat_tolerance end

  local function voice_param(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  local function extras(voice_idx) return S.voices[voice_idx].extras or {} end

  local function voice_length(voice_idx) return extras(voice_idx).seq_length or PATTERN_LENGTH end

  local function division_beats(voice_idx)
    return SEQ.division_beats[extras(voice_idx).seq_division or SEQ.default_division]
  end

  local function gated(voice_idx) return extras(voice_idx).seq_gate == SEQ.gate_on end

  local function sorted_keys(set)
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
  end

  local function copy_list(list)
    local copy = {}
    for index, value in ipairs(list) do copy[index] = value end
    return copy
  end

  -- Step attributes -------------------------------------------------------

  -- A list of 1..SEQ.max_step_notes whole degrees in -max..max, keyed 1..n
  -- with no hole
  local function valid_notes(list)
    if type(list) ~= "table" then return false end
    local count, last = 0, 0
    for key, degree in pairs(list) do
      if not whole_between(key, 1, SEQ.max_step_notes) then return false end
      if not whole_between(degree, -SEQ.max_degree, SEQ.max_degree) then return false end
      count, last = count + 1, math.max(last, key)
    end
    return count >= 1 and count == last
  end

  local function in_lock_range(voice_idx, key, value)
    local low, high = param_range(voice_param(voice_idx, SEQ.lock_params[key]))
    return number_between(value, low, high)
  end

  -- Per attribute key, whether a value is one it can hold (design 8.1, 8.12)
  local ATTR_CHECKS = {
    prob = function(value) return whole_between(value, 0, SEQ.max_prob) end,
    ratchet = function(value) return whole_between(value, 1, SEQ.max_ratchet) end,
    notes = valid_notes,
    pos = function(value, voice_idx) return in_lock_range(voice_idx, "pos", value) end,
    pitch = function(value, voice_idx) return in_lock_range(voice_idx, "pitch", value) end,
    size = function(value, voice_idx) return in_lock_range(voice_idx, "size", value) end,
    bookmark = function(value) return whole_between(value, 1, NUM_BOOKMARKS) end,
    gate = function(value) return number_between(value, SEQ.gate_steps[1], SEQ.gate_steps[2]) end,
  }

  local function valid_place(voice_idx, step)
    return valid_voice(voice_idx) and whole_between(step, 1, PATTERN_LENGTH)
  end

  -- A step attribute (a copy of a notes list), or nil
  function M.step_attr(voice_idx, step, key)
    if not valid_place(voice_idx, step) then return nil end
    local attrs = S.pattern_steps[voice_idx][step]
    local value = attrs and attrs[key]
    if type(value) == "table" then return copy_list(value) end
    return value
  end

  -- Set a step attribute: nil (or an empty notes list) clears it, and a
  -- step with none left is nil. An out-of-range voice, step, key or value
  -- does nothing. Each edit ends the voice's pattern undo and redraws
  function M.set_step_attr(voice_idx, step, key, value)
    if not valid_place(voice_idx, step) or ATTR_CHECKS[key] == nil then return end
    if key == "notes" and type(value) == "table" and next(value) == nil then value = nil end
    if value ~= nil and not ATTR_CHECKS[key](value, voice_idx) then return end
    local steps = S.pattern_steps[voice_idx]
    local attrs = steps[step] or {}
    if key == "notes" and value ~= nil then value = copy_list(value) end
    attrs[key] = value
    steps[step] = next(attrs) ~= nil and attrs or nil
    S.lib.mutation.note_pattern_edit(voice_idx)
    grid_redraw()
  end

  -- Whether a steps block (design 9.2) holds NUM_VOICES tables keyed by
  -- whole steps, each step a table of known attributes in range
  function M.valid_steps(steps)
    if type(steps) ~= "table" then return false end
    for voice_idx, voice_steps in pairs(steps) do
      if not valid_voice(voice_idx) or type(voice_steps) ~= "table" then return false end
      for step, attrs in pairs(voice_steps) do
        if not whole_between(step, 1, PATTERN_LENGTH) or type(attrs) ~= "table" then return false end
        for key, value in pairs(attrs) do
          if ATTR_CHECKS[key] == nil or not ATTR_CHECKS[key](value, voice_idx) then return false end
        end
      end
    end
    for voice_idx = 1, NUM_VOICES do
      if type(steps[voice_idx]) ~= "table" then return false end
    end
    return true
  end

  -- A copy of a steps block, every empty step dropped
  local function copy_steps(steps)
    local copy = {}
    for voice_idx = 1, NUM_VOICES do
      copy[voice_idx] = {}
      for step, attrs in pairs(steps[voice_idx] or {}) do
        local attrs_copy = {}
        for key, value in pairs(attrs) do
          attrs_copy[key] = type(value) == "table" and copy_list(value) or value
        end
        if next(attrs_copy) ~= nil then copy[voice_idx][step] = attrs_copy end
      end
    end
    return copy
  end

  -- Every voice's step attributes from a (valid) steps block
  local function set_all_steps(steps)
    local copy = copy_steps(steps)
    for voice_idx = 1, NUM_VOICES do S.pattern_steps[voice_idx] = copy[voice_idx] end
  end

  -- The steps scene block (design 8.1, 9.2): switched at a transition's
  -- end, before the patterns
  S.register_scene_block({
    key = "steps",
    default = function() return copy_steps({}) end,
    capture = function() return copy_steps(S.pattern_steps) end,
    validate = function(steps) return M.valid_steps(steps) end,
    apply = set_all_steps,
    discrete = true,
  })

  -- Overrides (step locks and notes) ---------------------------------------

  -- End every override a voice's step set: each param goes back to its
  -- stored value at once
  local function end_overrides(voice_idx)
    local held = overrides[voice_idx]
    overrides[voice_idx], last_played[voice_idx] = nil, nil
    if not held then return end
    for _, param_id in ipairs(sorted_keys(held)) do S.lib.engine_sync.clear_base_override(param_id) end
  end

  local function end_all_overrides()
    for voice_idx = 1, NUM_VOICES do end_overrides(voice_idx) end
  end

  -- Notes (design 8.4) ------------------------------------------------------

  local function log2(x) return math.log(x) / math.log(2) end

  -- The voice's own pitch as a (fractional) note: a synth voice's freq; a
  -- buffer or input voice's rate (buf_rate, grain_pitch) as the note a MIDI
  -- note plays at that rate (rate 1: MIDI's rate_root_note)
  local function voice_pitch_note(voice_idx)
    if voice_uses_synth(voice_idx) then
      return SEQ.a4_note + SEQ.semitones * log2(params:get(voice_param(voice_idx, "freq")) / SEQ.a4_freq)
    end
    local key = voice_uses_buffer(voice_idx) and "buf_rate" or "grain_pitch"
    return S.lib.midi_in.MIDI.rate_root_note + SEQ.semitones * log2(params:get(voice_param(voice_idx, key)))
  end

  -- The param a note transposes: freq, buf_rate or grain_pitch
  local function note_param(voice_idx)
    if voice_uses_synth(voice_idx) then return voice_param(voice_idx, "freq") end
    if voice_uses_buffer(voice_idx) then return voice_param(voice_idx, "buf_rate") end
    return voice_param(voice_idx, "grain_pitch")
  end

  -- The semitones from the voice's pitch to its k-th tone above (below, for
  -- a negative k) among the global scale's tones, the root included; 0 for
  -- degree 0. On the chromatic scale (the scale off) every semitone is a
  -- tone, counted from the voice's own pitch: k semitones, so a voice
  -- tuned between two notes keeps its tuning
  function M.degree_semitones(voice_idx, k)
    if not valid_voice(voice_idx) or not whole_between(k, -SEQ.max_degree, SEQ.max_degree) then return nil end
    local mask, root = S.lib.variation.scale_mask(), S.lib.variation.root()
    if k == 0 or mask == SEQ.chromatic_mask then return k end
    local pitch = voice_pitch_note(voice_idx)
    local direction = k > 0 and 1 or -1
    local tone = k > 0 and math.floor(pitch + SEQ.tone_tolerance) or math.ceil(pitch - SEQ.tone_tolerance)
    local found = 0
    -- a scale holds its root, so at most an octave passes between two tones
    for _ = 1, SEQ.semitones * (math.abs(k) + 1) do
      tone = tone + direction
      if math.floor(mask / 2 ^ ((tone - root) % SEQ.semitones)) % 2 == 1 then
        found = found + 1
        if found == math.abs(k) then return tone - pitch end
      end
    end
    return nil
  end

  -- The voices output (design 8.3) ---------------------------------------

  -- Send a voice's gate length, only when it differs from the one sent last
  local function send_gate_seconds(voice_idx, seconds)
    if gate_sent[voice_idx] == seconds then return end
    gate_sent[voice_idx] = seconds
    engine.setGrainParam(voice_idx - 1, "gateSeconds", seconds)
  end

  -- A step's gate in seconds: the step's gate (or the voice's length) in
  -- steps x the voice's nominal step in seconds / hits, clamped
  function M.gate_seconds(voice_idx, step, hits)
    if not valid_voice(voice_idx) then return nil end
    local steps = (step and M.step_attr(voice_idx, step, "gate")) or extras(voice_idx).seq_gate_length
      or SEQ.gate_length_default
    local seconds = steps * division_beats(voice_idx) * S.lib.params_setup.beat_seconds_now() / (hits or 1)
    return util.clamp(seconds, SEQ.gate_seconds[1], SEQ.gate_seconds[2])
  end

  -- A running gated voice's gate length now (a param edit)
  local function resend_gate(voice_idx)
    if S.voices[voice_idx].active and gated(voice_idx) then send_gate_seconds(voice_idx, M.gate_seconds(voice_idx)) end
  end

  -- Whether a voice's bookmark n lies inside its loop, where a recall moves
  -- only buf_pos (outside, lib/positions.lua's jump would reset the loop)
  local function bookmark_in_loop(voice_idx, n)
    local position = params:get(voice_param(voice_idx, "bookmark_" .. n))
    local start = params:get(voice_param(voice_idx, "loop_start"))
    local length = params:get(voice_param(voice_idx, "loop_length"))
    return position >= start and position < start + length - SEQ.loop_tolerance
  end

  -- A step's first hit on a voice: the locks, the bookmark and the note, as
  -- base overrides; the previous played step's overrides this one lacks end
  local function apply_step(voice_idx, event)
    local locks = event.locks or {}
    local sync = S.lib.engine_sync
    local wanted, lock_ids = {}, {}  -- param id -> value: the locks, then the note
    for _, key in ipairs(SEQ.lock_keys) do
      if SEQ.lock_params[key] and locks[key] ~= nil then
        local param_id = voice_param(voice_idx, SEQ.lock_params[key])
        wanted[param_id] = locks[key]
        lock_ids[#lock_ids + 1] = param_id
      end
    end
    -- the note, on its param's stored value (an input voice's: on the
    -- step's pitch lock), clamped to the param's range
    local semitones = event.semitones and event.semitones[1]
    local note_id = semitones and note_param(voice_idx)
    if note_id then
      local low, high = param_range(note_id)
      local value = (wanted[note_id] or params:get(note_id)) * 2 ^ (semitones / SEQ.semitones)
      if value == value and value > -math.huge and value < math.huge then
        wanted[note_id] = util.clamp(value, low, high)
      else
        note_id = nil
      end
    end
    for _, param_id in ipairs(sorted_keys(overrides[voice_idx] or {})) do
      if wanted[param_id] == nil then sync.clear_base_override(param_id) end
    end
    for _, param_id in ipairs(lock_ids) do
      if param_id ~= note_id then sync.set_base_override(param_id, wanted[param_id]) end
    end
    local n = locks.bookmark
    if n and S.lib.bookmarks.is_set(voice_idx, n) and bookmark_in_loop(voice_idx, n) then
      S.lib.bookmarks.recall(voice_idx, n)
    end
    if note_id then sync.set_base_override(note_id, wanted[note_id]) end
    local held = {}
    for param_id in pairs(wanted) do held[param_id] = true end
    overrides[voice_idx] = next(held) ~= nil and held or nil
    last_played[voice_idx] = event.step
  end

  -- Strata's own voices: a stopped voice is started at the step's first
  -- hit (a gated one is then retriggered), a running one retriggered at
  -- each hit, a gated one's gate length sent first when it changed. Never a
  -- node: start_voice for a stopped voice, retrigger for a running one
  local function voices_play(event)
    local voice_idx = event.voice
    local voice = S.voices[voice_idx]
    local started = false
    if event.first then
      if not voice.active then
        S.lib.engine_sync.start_voice(voice_idx)
        started = true
      end
      apply_step(voice_idx, event)
    end
    if not voice.active or (started and not gated(voice_idx)) then return end
    if gated(voice_idx) then send_gate_seconds(voice_idx, M.gate_seconds(voice_idx, event.step, event.hits)) end
    engine.retrigger(voice_idx - 1, event.velocity)
  end

  S.register_step_output({name = "voices", play = voices_play})

  -- The outputs (design 8.10) --------------------------------------------

  -- An output that failed prints once and is skipped until the next start
  local function output_failed(output, problem)
    if play.failed[output.name] then return end
    play.failed[output.name] = true
    print("step output " .. output.name .. ": " .. tostring(problem))
  end

  -- Each output's calls run in a coroutine of their own (a worker, kept
  -- per output and used again), so an error, or a wait (play never yields:
  -- it runs between the voice's syncs), fails that output and never
  -- reaches the voice's clock. A worker yields DONE after each call; any
  -- other yield is the output's own, and that worker is dropped
  local DONE = {}
  local workers = {}

  local function worker_body(fn, output, event)
    while true do
      fn(output, event)
      fn, output, event = coroutine.yield(DONE)
    end
  end

  local function run_output(fn, output, event)
    local worker = workers[output.name]
    if worker == nil or coroutine.status(worker) ~= "suspended" then worker = coroutine.create(worker_body) end
    workers[output.name] = nil
    local ran, result = coroutine.resume(worker, fn, output, event)
    if ran and result == DONE then
      workers[output.name] = worker
    else
      -- an error with the worker's traceback, for maiden
      output_failed(output, ran and "it must never yield (clock.sync or clock.sleep in play)"
        or debug.traceback(worker, tostring(result)))
    end
  end

  local function play_output(output, event)
    if output.available == nil or output.available(event.voice) then output.play(event) end
  end

  local function stop_output(output) output.stop() end

  local function play_outputs(event)
    for _, output in ipairs(S.registry.step_outputs) do
      if not play.failed[output.name] then run_output(play_output, output, event) end
    end
  end

  local function stop_outputs()
    for _, output in ipairs(S.registry.step_outputs) do
      if output.stop then run_output(stop_output, output) end
    end
  end

  -- A hit's event (design 8.10's fields)
  local function hit_event(voice_idx, step, hit, hits, level)
    local attrs = S.pattern_steps[voice_idx][step] or {}
    local division = division_beats(voice_idx)
    local event = {voice = voice_idx, step = step, hit = hit, hits = hits, first = hit == 1, level = level,
      velocity = level / MAX_STEP_LEVEL, beat = clock.get_beats(), gate_beats = division / hits}
    if gated(voice_idx) then
      event.gate_beats = (attrs.gate or extras(voice_idx).seq_gate_length) * division / hits
    end
    if attrs.notes then
      event.notes, event.semitones = copy_list(attrs.notes), {}
      for index, degree in ipairs(attrs.notes) do event.semitones[index] = M.degree_semitones(voice_idx, degree) end
    end
    for _, key in ipairs(SEQ.lock_keys) do
      if attrs[key] ~= nil then
        event.locks = event.locks or {}
        event.locks[key] = attrs[key]
      end
    end
    return event
  end

  -- The clocks (design 8.2, 8.13) ------------------------------------------

  -- Wait for target, on the beat timeline, from the last sync's beat (less
  -- than a period before it): the offset in (-period, 0] makes the
  -- scheduler land on the first beat at target modulo period after it
  local function sync_to(target, period)
    local offset = target % period
    if offset > 0 then offset = offset - period end
    clock.sync(period, offset)
  end

  -- The beat a voice's tick k falls on: anchor + k x division, every odd
  -- tick (the 2nd, 4th, ... step since the anchor) late by its swing
  local function swing_beats(voice_idx)
    local swing = extras(voice_idx).seq_swing or SEQ.swing[1]
    return (swing - SEQ.swing[1]) / SEQ.swing[1] * division_beats(voice_idx)
  end

  local function tick_beat(state, k, division, swing)
    return state.anchor + k * division + (k % 2 == 1 and swing or 0)
  end

  -- The voice's next tick after the step it played last, and its beat (a
  -- division reset's bar, when the voice would pass it)
  local function next_voice_tick(voice_idx)
    local state = play.voices[voice_idx]
    local division, swing = division_beats(voice_idx), swing_beats(voice_idx)
    local k = math.max(0, math.floor((state.beat - state.anchor) / division) - 1)
    while tick_beat(state, k, division, swing) <= state.beat + SEQ.beat_tolerance do k = k + 1 end
    local beat = tick_beat(state, k, division, swing)
    local reset = play.reset_beat
    if reset and state.anchor < reset - SEQ.beat_tolerance and beat > reset + SEQ.beat_tolerance then
      beat = reset
    end
    return k, beat, 2 * division
  end

  -- The transport's bar after its last 16th
  local function next_bar_beat()
    local state = play.transport
    local bars = math.floor((state.beat - state.anchor) / SEQ.bar_beats + SEQ.beat_tolerance) + 1
    return state.anchor + bars * SEQ.bar_beats
  end

  -- The participants' redraw (#527): the voices and the transport whose
  -- steps fall on one beat repaint the grid once, after the last of them;
  -- the screen too when one of them started a voice
  local function finish_beat(beat)
    for voice_idx = 1, NUM_VOICES do
      local due = play.voices[voice_idx].due
      if due and near(due, beat) then return end
    end
    if play.transport.due and near(play.transport.due, beat) then return end
    if play.started then
      play.started = false
      update_voice_list()
      request_redraw()
    end
    grid_redraw()
  end

  -- The chain (design 8.8) -----------------------------------------------

  -- The chain's slots: seq_chain_scenes of them from seq_chain_from
  local function chain_slots()
    local slots, from = {}, params:get("seq_chain_from")
    for offset = 0, math.min(params:get("seq_chain_scenes"), NUM_SCENES) - 1 do
      slots[#slots + 1] = (from - 1 + offset) % NUM_SCENES + 1
    end
    return slots
  end

  -- The populated scene after current in the chain's slots (wrapping, from
  -- seq_chain_from when current is none of them), or nil
  local function next_chain_scene(current)
    local slots, first = chain_slots(), 1
    for index, slot in ipairs(slots) do
      if slot == current then first = index + 1 end
    end
    for offset = 0, #slots - 1 do
      local slot = slots[(first - 1 + offset) % #slots + 1]
      if S.scenes[slot] and S.scenes[slot].populated and validate_scene(S.scenes[slot]) then return slot end
    end
    return nil
  end

  -- A link: the scene's patterns, steps block and each voice's length and
  -- division, and nothing else; every override ends
  local function load_chain_scene(slot)
    local data = S.scenes[slot].data
    chain.current = slot
    end_all_overrides()
    for voice_idx = 1, NUM_VOICES do M.replace_pattern(voice_idx, data.patterns[voice_idx]) end
    set_all_steps(data.steps or {})
    for voice_idx = 1, NUM_VOICES do
      local scene_extras = data.voices[voice_idx].extras or {}
      for _, key in ipairs({"seq_length", "seq_division"}) do
        if scene_extras[key] then params:set(voice_param(voice_idx, key), scene_extras[key]) end
      end
    end
  end

  local function chain_link()
    local slot = next_chain_scene(chain.current)
    if slot then load_chain_scene(slot) end
  end

  -- Whatever falls on a beat before its steps: a chain link due then (the
  -- first participant to reach it links, for all)
  local function at_beat(beat)
    if chain.next_beat and beat >= chain.next_beat - SEQ.beat_tolerance then
      chain.next_beat = chain.next_beat + params:get("seq_chain_bars") * SEQ.bar_beats
      chain_link()
    end
  end

  -- A voice's step ------------------------------------------------------

  -- The voice's step at its tick: the position wraps at the pass's length
  -- (a length change applies at once while the position is inside it, at
  -- the wrap otherwise); a set step draws its probability once and plays
  -- its first hit; returns the hits still to play and their spacing
  local function begin_voice_step(voice_idx)
    local state = play.voices[voice_idx]
    at_beat(state.beat)
    local length = voice_length(voice_idx)
    if length ~= state.pass_length and state.position <= length then state.pass_length = length end
    if state.position > state.pass_length then state.position, state.pass_length = 1, length end
    local step = state.position
    S.pattern_sounding_steps[voice_idx], state.position = step, step + 1
    local level = S.patterns[voice_idx][step]
    local hits, spacing = 0, 0
    local attrs = S.pattern_steps[voice_idx][step] or {}
    local prob = attrs.prob or SEQ.max_prob
    if level > 0 and prob > 0 and (prob >= SEQ.max_prob or math.random() * SEQ.max_prob < prob) then
      -- the step's own length (a swung pair's), which the 20 ms rule reads
      local division, swing = division_beats(voice_idx), swing_beats(voice_idx)
      local step_beats = division + (state.tick % 2 == 0 and swing or -swing)
      local step_seconds = step_beats * S.lib.params_setup.beat_seconds_now()
      hits = math.min(attrs.ratchet or 1, math.max(1, math.floor(step_seconds / SEQ.min_ratchet_seconds + 1e-9)))
      spacing = step_beats / hits
      local was_active = S.voices[voice_idx].active
      play_outputs(hit_event(voice_idx, step, 1, hits, level))
      if S.voices[voice_idx].active and not was_active then play.started = true end
    end
    finish_beat(state.beat)
    return {step = step, level = level, hits = hits, spacing = spacing, beat = state.beat}
  end

  local function play_voice_hit(voice_idx, plan, hit)
    play_outputs(hit_event(voice_idx, plan.step, hit, plan.hits, plan.level))
  end

  -- The transport's 16th: a link due, a division reset's bar (every voice
  -- not yet back at step 1 restarts there), its count, the redraw
  local function transport_step()
    local state = play.transport
    at_beat(state.beat)
    local reset = play.reset_beat
    if reset and state.beat >= reset - SEQ.beat_tolerance then
      play.reset_beat = nil
      for voice_idx = 1, NUM_VOICES do
        if play.voices[voice_idx].anchor < reset - SEQ.beat_tolerance then M.restart_voice(voice_idx, reset) end
      end
    end
    S.pattern_sounding_step = S.pattern_position
    S.pattern_position = S.pattern_position % PATTERN_LENGTH + 1
    finish_beat(state.beat)
  end

  -- A clock's step through xpcall: an error forgets the clock's own id
  -- (forget), so the stop never cancels this clock from inside itself,
  -- shows the patterns stopped (the grid, the header's play mark, SEQ, and
  -- MAIN with the voices a step started) and is raised again (#243)
  local function guarded(forget, fn)
    local ran, result = xpcall(fn, with_traceback)
    if ran then return result end
    forget()
    pattern_clock_stop()
    update_voice_list()
    request_redraw()
    -- level 0: the message already carries its traceback
    error(result, 0)
  end

  -- A voice's clock from beat (its step 1 at once, its anchor): each step,
  -- its ratchets, then the wait for its next tick. Every wait is outside
  -- the guard
  local function voice_clock(voice_idx, beat)
    local state = play.voices[voice_idx]
    state.anchor, state.tick, state.beat, state.due = beat, 0, beat, nil
    state.position, state.pass_length = 1, voice_length(voice_idx)
    local function forget() S.pattern_clocks[voice_idx] = nil end
    local function begin() return begin_voice_step(voice_idx) end
    local plan = guarded(forget, begin)
    while true do
      for hit = 2, plan.hits do
        sync_to(plan.beat + (hit - 1) * plan.spacing, plan.spacing)
        guarded(forget, function() play_voice_hit(voice_idx, plan, hit) end)
      end
      local next_tick = guarded(forget, function()
        local k, target, period = next_voice_tick(voice_idx)
        return {k = k, target = target, period = period}
      end)
      state.due = next_tick.target
      sync_to(next_tick.target, next_tick.period)
      state.due = nil
      guarded(forget, function()
        local reset, k = play.reset_beat, next_tick.k
        if reset and near(next_tick.target, reset) and state.anchor < reset - SEQ.beat_tolerance then
          -- the division reset's bar: step 1, from here
          state.anchor, k = reset, 0
          state.position, state.pass_length = 1, voice_length(voice_idx)
        end
        state.tick, state.beat = k, next_tick.target
      end)
      plan = guarded(forget, begin)
    end
  end

  -- Start (or start again) voice_idx's clock at beat, now
  function M.restart_voice(voice_idx, beat)
    if S.pattern_clocks[voice_idx] then clock.cancel(S.pattern_clocks[voice_idx]) end
    S.pattern_clocks[voice_idx] = nil
    S.pattern_clocks[voice_idx] = clock.run(voice_clock, voice_idx, beat)
  end

  local function transport_clock(beat)
    local state = play.transport
    state.anchor, state.tick, state.beat, state.due = beat, 0, beat, nil
    local function forget() S.pattern_clock = nil end
    guarded(forget, transport_step)
    while true do
      local target = state.anchor + (state.tick + 1) * SEQ.transport_beats
      state.due = target
      sync_to(target, 2 * SEQ.transport_beats)
      state.due = nil
      state.tick, state.beat = state.tick + 1, target
      guarded(forget, transport_step)
    end
  end

  -- Cancel every clock of the patterns (the voices' and the transport's)
  local function cancel_clocks()
    for voice_idx = 1, NUM_VOICES do
      if S.pattern_clocks[voice_idx] then clock.cancel(S.pattern_clocks[voice_idx]) end
      S.pattern_clocks[voice_idx], S.pattern_sounding_steps[voice_idx] = nil, nil
      play.voices[voice_idx] = {anchor = 0, tick = 0, beat = 0, position = 1, pass_length = PATTERN_LENGTH}
    end
    if S.pattern_clock then clock.cancel(S.pattern_clock) end
    S.pattern_clock = nil
    play.transport = {anchor = 0, tick = 0, beat = 0}
  end
  cancel_clocks()

  -- Pattern edits ---------------------------------------------------------

  function toggle_pattern_step(voice_idx, step)
    -- Bounds checking to prevent array expansion
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    if step < 1 or step > PATTERN_LENGTH then return end

    if S.patterns[voice_idx][step] == 0 then
      S.patterns[voice_idx][step] = MAX_STEP_LEVEL  -- full brightness
    else
      S.patterns[voice_idx][step] = 0
    end
    S.lib.mutation.note_pattern_edit(voice_idx)
  end

  -- A step level from any value: a number floored to a whole level and
  -- clamped to 0..MAX_STEP_LEVEL; anything else (nil, a string, NaN) is 0
  local function whole_step_level(value)
    if type(value) ~= "number" or value ~= value then return 0 end
    return math.min(MAX_STEP_LEVEL, math.max(0, math.floor(value)))
  end

  -- Replace voice_idx's whole pattern: step s takes steps[s] as a whole
  -- level. A voice outside 1..NUM_VOICES or a steps that is not a table
  -- does nothing. It ends the voice's step-level gesture on every grid
  -- (#242), so a step held from before never takes a level in the new
  -- pattern, and the voice's overrides (its locks and note: no step of the
  -- old pattern will end them). Every whole-pattern change goes through it;
  -- it redraws nothing (callers do)
  function M.replace_pattern(voice_idx, steps)
    if type(voice_idx) ~= "number" or voice_idx % 1 ~= 0 then return end
    if voice_idx < 1 or voice_idx > NUM_VOICES or type(steps) ~= "table" then return end
    for step = 1, PATTERN_LENGTH do
      S.patterns[voice_idx][step] = whole_step_level(steps[step])
    end
    end_overrides(voice_idx)
    S.lib.grid_core.end_step_gestures(voice_idx)
    S.lib.mutation.note_pattern_edit(voice_idx)
  end

  function clear_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    M.replace_pattern(voice_idx, {})
  end

  function randomize_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local steps = {}
    for step = 1, PATTERN_LENGTH do
      if math.random() > 0.5 then
        steps[step] = math.random(RANDOM_STEP_FLOOR, MAX_STEP_LEVEL)
      else
        steps[step] = 0
      end
    end
    M.replace_pattern(voice_idx, steps)
  end

  -- Euclidean fill (design 8.5): the voice's first length steps from
  -- er.gen(hits, length, rotation), hits at MAX_STEP_LEVEL and the rest 0;
  -- the steps past the length and every attribute are kept. Nothing while a
  -- scene recall is in progress
  function M.euclid(voice_idx, hits, rotation)
    if not valid_voice(voice_idx) or S.scene_recall_in_progress then return end
    local length = voice_length(voice_idx)
    if not whole_between(hits, 0, length) or not whole_between(rotation, -PATTERN_LENGTH, PATTERN_LENGTH) then return end
    local fill, steps = er.gen(hits, length, rotation), {}
    for step = 1, PATTERN_LENGTH do
      steps[step] = step <= length and (fill[step] and MAX_STEP_LEVEL or 0) or S.patterns[voice_idx][step]
    end
    M.replace_pattern(voice_idx, steps)
    S.seq_euclid[voice_idx] = {hits, rotation}
    grid_redraw()
  end

  -- Playing and stopping ------------------------------------------------

  -- The play key, SEQ and the grids: a start waits for the quantizer
  -- (key "patterns"), a stop never does
  function pattern_toggle()
    if S.pattern_playing then
      pattern_clock_stop()
    else
      S.lib.quantize.schedule("patterns", pattern_clock_start, "play")
    end
  end

  -- Start (or start again) the patterns now: every voice and the transport
  -- at step 1 on this beat, a running chain at its first scene, and every
  -- output that failed is played again
  function pattern_clock_start()
    cancel_clocks()
    play.failed, play.started, play.reset_beat = {}, false, nil
    S.pattern_playing = true
    S.pattern_position = 1
    S.pattern_sounding_step = nil
    local beat = clock.get_beats()
    -- every participant is due on this beat, so the last of them repaints
    for voice_idx = 1, NUM_VOICES do play.voices[voice_idx].due = beat end
    play.transport.due = beat
    chain.current, chain.next_beat = nil, nil
    if params:get("seq_chain") == 1 then
      chain_link()
      chain.next_beat = beat + params:get("seq_chain_bars") * SEQ.bar_beats
    end
    for voice_idx = 1, NUM_VOICES do M.restart_voice(voice_idx, beat) end
    S.pattern_clock = clock.run(transport_clock, beat)
  end

  -- Stop the patterns: every clock canceled, the playheads cleared, every
  -- override ended and (when they played) every output's stop run
  function pattern_clock_stop()
    local was_playing = S.pattern_playing
    S.pattern_playing = false
    S.pattern_sounding_step = nil
    cancel_clocks()
    play.reset_beat, chain.next_beat = nil, nil
    end_all_overrides()
    if was_playing then stop_outputs() end
    grid_redraw()
  end

  -- The params ----------------------------------------------------------

  -- The chain switched on while the patterns play links at the next bar
  local function chain_switched(on)
    chain.current = nil
    chain.next_beat = (on == 1 and S.pattern_playing) and next_bar_beat() or nil
  end

  -- strata_seq (design 8.8): the chain, the quantizer's params
  -- (S.lib.quantize.PARAM_COUNT of them), the division reset and following
  -- the transport. PSETs store them; scenes don't
  function M.add_params()
    params:add_group("strata_seq", "sequencer", SEQ.group_params + S.lib.quantize.PARAM_COUNT)
    params:add{type = "binary", id = "seq_chain", name = "chain", behavior = "toggle", default = 0,
      action = chain_switched}
    params:add{type = "number", id = "seq_chain_from", name = "chain from", min = 1, max = NUM_SCENES,
      default = SEQ.chain_defaults.from}
    params:add{type = "number", id = "seq_chain_scenes", name = "chain scenes", min = 1, max = NUM_SCENES,
      default = SEQ.chain_defaults.scenes}
    params:add{type = "number", id = "seq_chain_bars", name = "chain bars", min = 1, max = SEQ.max_chain_bars,
      default = SEQ.chain_defaults.bars}
    S.lib.quantize.add_params()
    params:add{type = "trigger", id = "seq_division_reset", name = "division reset", action = function()
      if S.pattern_playing then play.reset_beat = next_bar_beat() end
    end}
    params:add{type = "binary", id = "seq_follow_transport", name = "follow transport", behavior = "toggle",
      default = 1}
  end

  -- The per-voice seq params (design 8.1, 8.12, 8.13): a registered record
  -- with discrete scene keys (length, division, gate, swing) and two that
  -- crossfade (the gate's length and release), no VOICE rows
  local record
  record = {
    name = "seq",
    count = 6,
    add = function(voice_idx)
      local add = S.lib.params_setup.add_voice_extra
      add(voice_idx, record, "seq_length", {type = "number", name = "seq length", min = 1, max = PATTERN_LENGTH,
        default = PATTERN_LENGTH, action = function(length)
          -- the step that set the voice's overrides is past the new length:
          -- no step of it will end them
          if (last_played[voice_idx] or 0) > length then end_overrides(voice_idx) end
          grid_redraw()
        end})
      add(voice_idx, record, "seq_division", {type = "option", name = "seq division", options = SEQ.division_names,
        default = SEQ.default_division})
      add(voice_idx, record, "seq_gate", {type = "option", name = "seq gate", options = SEQ.gate_options, default = 1,
        action = function() resend_gate(voice_idx) end})
      add(voice_idx, record, "seq_gate_length", {type = "control", name = "seq gate length",
        controlspec = controlspec.new(SEQ.gate_steps[1], SEQ.gate_steps[2], "exp", 0, SEQ.gate_length_default, "st"),
        action = function() resend_gate(voice_idx) end})
      add(voice_idx, record, "seq_gate_release", {type = "control", name = "seq gate release",
        controlspec = controlspec.new(SEQ.gate_release[1], SEQ.gate_release[2], "exp", 0, SEQ.gate_release_default,
          "s")})
      add(voice_idx, record, "seq_swing", {type = "number", name = "seq swing", min = SEQ.swing[1], max = SEQ.swing[2],
        default = SEQ.swing[1]})
    end,
    grain_keys = {seq_gate = {name = "seqGate", value = function(option) return option - 1 end},
      seq_gate_release = "gateRelease"},
    -- the voice sync and a start (before voiceOn: grain params only): a
    -- gated voice's gate length, when it changed
    sync = function(voice_idx)
      if gated(voice_idx) then send_gate_seconds(voice_idx, M.gate_seconds(voice_idx)) end
    end,
    scene_defaults = {seq_length = PATTERN_LENGTH, seq_division = SEQ.default_division, seq_gate = 1,
      seq_gate_length = SEQ.gate_length_default, seq_gate_release = SEQ.gate_release_default, seq_swing = SEQ.swing[1]},
    discrete = {seq_length = {1, PATTERN_LENGTH}, seq_division = {1, #SEQ.division_names},
      seq_gate = {1, #SEQ.gate_options}, seq_swing = {SEQ.swing[1], SEQ.swing[2]}},
    scene_ranges = {seq_gate_length = {SEQ.gate_steps[1], SEQ.gate_steps[2]},
      seq_gate_release = {SEQ.gate_release[1], SEQ.gate_release[2]}},
    fader = false,
  }
  S.register_voice_params(record)

  -- The clock's transport (#530, design 8.11) ----------------------------

  -- norns calls clock.transport.start and stop when the clock source starts
  -- or stops (a MIDI start or stop, a Link start or stop with start/stop
  -- sync on; on the internal clock, PARAMETERS > CLOCK > reset). The
  -- patterns follow only an external source's (MIDI, Link or crow), and
  -- only while seq_follow_transport is on: a start plays them from step 1
  -- at once, on the source's beat 0, whether they played or not (and a
  -- running chain from seq_chain_from), never through the quantizer; a stop
  -- stops them as the play key does. Strata never starts or stops the
  -- transport itself. Both redraw the screen (the header's play mark, SEQ).
  -- The handlers found at install still run after the script's, whatever
  -- the source or the param, and cleanup gives them back unless a handler
  -- installed later has replaced the script's.
  -- internal_source: the clock_source param's "internal" (the first of
  -- clock.add_params' options: internal, midi, link, crow)
  local transport = {previous_start = nil, previous_stop = nil, internal_source = 1}

  -- Whether a transport start or stop moves the patterns now
  function M.follows_transport()
    return params:get("seq_follow_transport") == 1 and params:get("clock_source") ~= transport.internal_source
  end

  function transport.start()
    if M.follows_transport() then
      pattern_clock_start()
      request_redraw()
    end
    if transport.previous_start then transport.previous_start() end
  end

  function transport.stop()
    if M.follows_transport() then
      pattern_clock_stop()
      request_redraw()
    end
    if transport.previous_stop then transport.previous_stop() end
  end

  -- Installing them again (init run twice) changes nothing: the script's
  -- handlers never chain to themselves
  S.register_start(S.constants.START_ORDER.pattern_transport, function()
    if clock.transport.start ~= transport.start then
      transport.previous_start, clock.transport.start = clock.transport.start, transport.start
    end
    if clock.transport.stop ~= transport.stop then
      transport.previous_stop, clock.transport.stop = clock.transport.stop, transport.stop
    end
  end)

  -- The step sounding now. With a voice, the one that voice's clock played
  -- last; with none, the transport's 16th (the position before
  -- S.pattern_position, which the clock has already advanced). nil while
  -- stopped and before the first step plays. Every playhead (each grid
  -- layout through step_brightness, SEQ) is one of these
  function M.sounding_step(voice_idx)
    if not S.pattern_playing then return nil end
    local step = S.pattern_sounding_step
    if voice_idx ~= nil then
      if not valid_voice(voice_idx) then return nil end
      step = S.pattern_sounding_steps[voice_idx]
    end
    if type(step) ~= "number" or step < 1 or step > PATTERN_LENGTH then return nil end
    return step
  end

  -- LED level for a pattern step: at the voice's playhead (its sounding
  -- step) 15 for a set step and 4 for an empty one; past the voice's length
  -- SEQ.past_length_level for a set step, 0 for an empty one; else its level
  function step_brightness(voice_idx, step)
    local level = S.patterns[voice_idx][step]
    if step == M.sounding_step(voice_idx) then
      return level > 0 and SEQ.playing_level or SEQ.playing_empty_level
    end
    if step > voice_length(voice_idx) then return level > 0 and SEQ.past_length_level or 0 end
    return level
  end

  -- Stop the pattern clocks and give the clock its transport handlers back
  S.register_cleanup(S.constants.CLEANUP_ORDER.pattern_clock, function()
    pattern_clock_stop()
    if clock.transport.start == transport.start then
      clock.transport.start, transport.previous_start = transport.previous_start, nil
    end
    if clock.transport.stop == transport.stop then
      clock.transport.stop, transport.previous_stop = transport.previous_stop, nil
    end
  end)

  -- The patterns play exactly while their clocks run: the transport's and
  -- every voice's
  S.register_invariant("pattern clock", function()
    if S.pattern_playing ~= (S.pattern_clock ~= nil) then
      return "pattern_playing is " .. tostring(S.pattern_playing) .. " but pattern_clock is " .. tostring(S.pattern_clock)
    end
    for voice_idx = 1, NUM_VOICES do
      if S.pattern_playing ~= (S.pattern_clocks[voice_idx] ~= nil) then
        return "pattern_playing is " .. tostring(S.pattern_playing) .. " but voice " .. voice_idx .. "'s clock is "
          .. tostring(S.pattern_clocks[voice_idx])
      end
    end
  end)

  return M
end

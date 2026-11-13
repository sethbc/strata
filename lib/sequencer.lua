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
    -- beats: a wake this far before its hop's beat is still on time (ruling
    -- 54): above a tick's jitter (a late MIDI or internal tick pulls the beat
    -- back a few ms), under the shortest division (1/32: 1/8 beat)
    wake_tolerance = 1 / 32,
    -- beats: a wake this late or later is not (ruling 58): under it a late
    -- resume plays and the count stays; a 16th, the transport's step
    late_beats = 1 / 4,
    hop_beats = 1 / 4,               -- no wait spans more than a 16th (wait_for)
    flt_epsilon = 2 ^ -23,           -- matron's FLT_EPSILON (clock_scheduler_next_clock_beat)
    loop_tolerance = 1e-6,           -- as lib/positions.lua's jump: inside the loop
    note_owner = "seq",              -- a chord's notes in S.lib.notes (design §4)
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
  -- {anchor, tick, beat, due, position, pass_length} and the transport's
  -- {anchor, tick, beat, due, played_at (the time of its last 16th)}, each
  -- with its wait's {last_sync, generation, sync_time, sync_beat,
  -- sync_beat_seconds, stale}. A
  -- participant's beats (the beat of its tick 0, of the step it played
  -- last, of the step it waits for) are on the sequencer's own count, the
  -- clock's beats plus play.offset: 0 from every pattern start, and set
  -- whenever the clock's beat jumps while they play (a transport start the
  -- patterns do not follow, a new clock source: play.keep_count, below,
  -- rulings 47, 54 and 58), so every clock, the bars and the ratchets stay
  -- in step through it; play.generation rises with each. last_sync: the
  -- clock beat the scheduler counts the participant's next sync from, and
  -- generation the play.generation it synced in; sync_time, sync_beat and
  -- sync_beat_seconds: the time, the beat and a beat's length when it
  -- synced; stale: last_sync may be an old count's (a sleep resets it);
  -- waiting: "sync" or "sleep" while it waits on one (nil while it runs);
  -- retired: its clock's id once ended (end_clock).
  -- play.failed: the
  -- outputs skipped until the next start; play.started: a voice started
  -- since the last redraw; play.reset_beat: a division reset's bar;
  -- play.retired: [id] = true for each clock ended but left to finish at its
  -- next wake (end_clock);
  -- overrides: per voice, the param ids its last played step overrides;
  -- last_played: per voice, that step; gate_sent: per voice, the
  -- gateSeconds sent last; chords: per voice, the notes its last played
  -- step plays through S.lib.notes (owner "seq", key k: the step's k-th
  -- note), {note_id, count, pitches, values} (step_chord), or nil
  local play = {voices = {}, transport = {}, failed = {}, started = false, reset_beat = nil, offset = 0,
    generation = 0, retired = {}}
  local overrides, last_played, gate_sent, chords = {}, {}, {}, {}
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

  -- Whether a voice has a set step (a level above 0) inside its length
  function M.has_set_step(voice_idx)
    if not valid_voice(voice_idx) then return false end
    for step = 1, voice_length(voice_idx) do
      if S.patterns[voice_idx][step] > 0 then return true end
    end
    return false
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

  -- Set and clear one override. A synth voice's freq is also its grain
  -- quantize's reference note (scaleNote, lib/variation.lua), which is
  -- resent on every change that moves it: the step's freq, then the voice's
  -- own (send_scale_note sends to a running voice only)
  local function set_override(voice_idx, param_id, value)
    S.lib.engine_sync.set_base_override(param_id, value)
    if param_id == voice_param(voice_idx, "freq") then S.lib.variation.send_scale_note(voice_idx, value) end
  end

  local function clear_override(voice_idx, param_id)
    S.lib.engine_sync.clear_base_override(param_id)
    if param_id == voice_param(voice_idx, "freq") then S.lib.variation.send_scale_note(voice_idx) end
  end

  -- A voice's chord ends (design §4): every note its last played step
  -- plays is released, an extra note with noteOff, the first (the voice's
  -- own) sending nothing (it asked no park: its override ends with the
  -- overrides). Run once: with no chord, nothing
  local function end_chord(voice_idx)
    if chords[voice_idx] == nil then return end
    chords[voice_idx] = nil
    S.lib.notes.release_owner(voice_idx, SEQ.note_owner)
  end

  -- End every override a voice's step set, and its chord: each param goes
  -- back to its stored value at once
  local function end_overrides(voice_idx)
    end_chord(voice_idx)
    local held = overrides[voice_idx]
    overrides[voice_idx], last_played[voice_idx] = nil, nil
    if not held then return end
    for _, param_id in ipairs(sorted_keys(held)) do clear_override(voice_idx, param_id) end
  end

  local function end_all_overrides()
    for voice_idx = 1, NUM_VOICES do end_overrides(voice_idx) end
  end

  -- Notes (design 8.4) ------------------------------------------------------

  local function log2(x) return math.log(x) / math.log(2) end

  -- The param a note transposes: freq, buf_rate or grain_pitch
  local function note_param(voice_idx)
    if voice_uses_synth(voice_idx) then return voice_param(voice_idx, "freq") end
    if voice_uses_buffer(voice_idx) then return voice_param(voice_idx, "buf_rate") end
    return voice_param(voice_idx, "grain_pitch")
  end

  -- A value of the param a note transposes (note_param) as a (fractional)
  -- note: a synth voice's freq; a buffer or input voice's rate (buf_rate,
  -- grain_pitch) as the note a MIDI note plays at that rate (rate 1: MIDI's
  -- rate_root_note)
  local function value_note(voice_idx, value)
    if voice_uses_synth(voice_idx) then return SEQ.a4_note + SEQ.semitones * log2(value / SEQ.a4_freq) end
    return S.lib.midi_in.MIDI.rate_root_note + SEQ.semitones * log2(value)
  end

  -- The voice's own pitch as a (fractional) note: its note param's stored value's
  local function voice_pitch_note(voice_idx) return value_note(voice_idx, params:get(note_param(voice_idx))) end

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

  -- Before a retrigger outside the patterns (a MIDI note, lib/midi_in.lua):
  -- a running gated voice's own gate length, when the last one sent was a
  -- step's (its gate, a ratchet's share), which the stage would keep (#639)
  function M.note_gate(voice_idx)
    if valid_voice(voice_idx) then resend_gate(voice_idx) end
  end

  -- Whether a voice's bookmark n lies inside its loop, where a recall moves
  -- only buf_pos (outside, lib/positions.lua's jump would reset the loop)
  local function bookmark_in_loop(voice_idx, n)
    local position = params:get(voice_param(voice_idx, "bookmark_" .. n))
    local start = params:get(voice_param(voice_idx, "loop_start"))
    local length = params:get(voice_param(voice_idx, "loop_length"))
    return position >= start and position < start + length - SEQ.loop_tolerance
  end

  local function finite(value) return type(value) == "number" and value == value and value > -math.huge
    and value < math.huge end

  -- A step's chord (design §4): note k's value (its note param's, the
  -- stored value or the step's lock on it, x 2^(semitones / 12), clamped to
  -- the param's range: 3.4's note override for the first) and its pitch
  -- (that same base as a note, plus its semitones), every note from the one
  -- base the first note's override is worked out from (ruling 27: an input
  -- voice's pitch lock included). nil without notes, or when the first
  -- note's value is not a finite number
  local function step_chord(voice_idx, semitones, wanted)
    if not semitones or semitones[1] == nil then return nil end
    local note_id = note_param(voice_idx)
    local low, high = param_range(note_id)
    local base = wanted[note_id] or params:get(note_id)
    local base_note = value_note(voice_idx, base)
    local chord = {note_id = note_id, count = #semitones, pitches = {}, values = {}}
    for k = 1, chord.count do
      if type(semitones[k]) == "number" then
        local value = base * 2 ^ (semitones[k] / SEQ.semitones)
        if finite(value) then chord.values[k] = util.clamp(value, low, high) end
        chord.pitches[k] = base_note + semitones[k]
      end
    end
    if chord.values[1] == nil then return nil end
    return chord
  end

  -- Whether another owner (MIDI) holds the voice's slot 1: a held note,
  -- not parked, whose owner is not the sequencer, and (ruling 55) whose key
  -- is down: MIDI forgets a latched own note here, which then gives way
  local function other_owns_slot_1(voice_idx)
    for _, used in ipairs(S.lib.notes.slots(voice_idx)) do
      if used.slot == 1 then
        return used.held and not used.parked and used.owner ~= SEQ.note_owner and S.lib.midi_in.keeps_own(voice_idx)
      end
    end
    return false
  end

  -- Note k of a chord for S.lib.notes.play. own: the note may be the
  -- voice's own, quiet (the voices output starts and accents the voice
  -- itself, ruling 13) with every branch, as the step's note was in 3.4: the
  -- first note, unless another owner holds slot 1. Any other is extra_only
  -- (rulings 32 and 35): its own held slot again, or a free extra slot with
  -- room in the pool; never slot 1, never a steal: else refused. So a step
  -- never takes a slot or a note from another owner. set_own makes the note
  -- the voice's own: its value as the note override (3.4's), held with the
  -- step's overrides
  local function chord_note(voice_idx, chord, k, velocity, own)
    return {owner = SEQ.note_owner, key = k, pitch = chord.pitches[k], velocity = velocity, park = false,
      quiet = own, extra_only = not own,
      set_own = function()
        if chord.values[k] == nil then return end
        set_override(voice_idx, chord.note_id, chord.values[k])
        overrides[voice_idx] = overrides[voice_idx] or {}
        overrides[voice_idx][chord.note_id] = true
      end}
  end

  -- The reviewer's minor 1 (ruling 55): the step's first note held in an
  -- extra slot while slot 1 holds no note (MIDI let go of it: a latched
  -- note given way, or a reset) is released there, so the step's note is
  -- the voice's own again rather than an extra note over the own note's
  -- drone. A parked own note is left: it is silent, the extra note plays on
  local function leave_extra_slot(voice_idx)
    local first = S.lib.notes.slots(voice_idx)[1]
    local slot = S.lib.notes.find(voice_idx, SEQ.note_owner, 1)
    if slot and slot > 1 and not (first and first.slot == 1) then S.lib.notes.release(voice_idx, SEQ.note_owner, 1) end
  end

  -- The step's first note is not the voice's own (an extra note, none, or
  -- MIDI took it): the note param keeps the step's lock on it, or goes back
  -- to its stored value
  local function end_note_override(voice_idx, note_id, lock_value)
    if lock_value ~= nil then
      set_override(voice_idx, note_id, lock_value)
    elseif overrides[voice_idx] and overrides[voice_idx][note_id] then
      clear_override(voice_idx, note_id)
    end
  end

  -- The reviewer's minor 2: a MIDI note took the voice's own note from the
  -- step's (branch 6: the voice's cap or the pool full; lib/midi_in.lua
  -- calls this when its note lands on slot 1). The step's note override
  -- ends at once, as for a first note that is not the voice's own, so MIDI's
  -- pitch plays now rather than at the next step. Nothing when the step's
  -- first note was not the voice's own or still is
  function M.own_note_taken(voice_idx)
    local chord = valid_voice(voice_idx) and chords[voice_idx]
    if not (chord and chord.own) or S.lib.notes.find(voice_idx, SEQ.note_owner, 1) == 1 then return end
    chord.own = false
    end_note_override(voice_idx, chord.note_id, chord.lock_value)
    local held = overrides[voice_idx]
    if held and chord.lock_value == nil then
      held[chord.note_id] = nil
      if next(held) == nil then overrides[voice_idx] = nil end
    end
  end

  -- A step's first hit on a voice: the locks, the bookmark and the note, as
  -- base overrides; the previous played step's overrides this one lacks
  -- end, and its chord's notes this one lacks are released (by key: a note
  -- it keeps is played again in place). The first note plays here, where
  -- 3.4 set its override: the voice's own (slot 1) as that override, or,
  -- while another owner holds slot 1, only an extra note in free room
  -- (ruling 35), with no note override
  local function apply_step(voice_idx, event)
    local locks = event.locks or {}
    local wanted, lock_ids = {}, {}  -- param id -> value: the locks, then the note
    for _, key in ipairs(SEQ.lock_keys) do
      if SEQ.lock_params[key] and locks[key] ~= nil then
        local param_id = voice_param(voice_idx, SEQ.lock_params[key])
        wanted[param_id] = locks[key]
        lock_ids[#lock_ids + 1] = param_id
      end
    end
    local chord = step_chord(voice_idx, event.semitones, wanted)
    local note_id = chord and chord.note_id
    local lock_value = note_id and wanted[note_id]  -- an input voice's pitch lock, the note's own param
    if note_id then wanted[note_id] = chord.values[1] end
    for k = (chord and chord.count or 0) + 1, SEQ.max_step_notes do
      S.lib.notes.release(voice_idx, SEQ.note_owner, k)
    end
    for _, param_id in ipairs(sorted_keys(overrides[voice_idx] or {})) do
      if wanted[param_id] == nil then clear_override(voice_idx, param_id) end
    end
    for _, param_id in ipairs(lock_ids) do
      if param_id ~= note_id then set_override(voice_idx, param_id, wanted[param_id]) end
    end
    local n = locks.bookmark
    if n and S.lib.bookmarks.is_set(voice_idx, n) and bookmark_in_loop(voice_idx, n) then
      S.lib.bookmarks.recall(voice_idx, n)
    end
    chords[voice_idx] = chord
    local own = note_id and not other_owns_slot_1(voice_idx)
    if own then leave_extra_slot(voice_idx) end
    if note_id then
      chord.lock_value = lock_value
      chord.own = S.lib.notes.play(voice_idx, chord_note(voice_idx, chord, 1, event.velocity, own)) == 1
      if not chord.own then
        -- an extra note, or none
        wanted[note_id] = lock_value
        end_note_override(voice_idx, note_id, lock_value)
      end
    end
    local held = {}
    for param_id in pairs(wanted) do held[param_id] = true end
    overrides[voice_idx] = next(held) ~= nil and held or nil
    last_played[voice_idx] = event.step
  end

  -- A chord's further notes, on a running voice after its start and
  -- retrigger (ruling 13: only a running voice gets an extra slot): at the
  -- step's first hit notes 2 to n; at a later hit (a ratchet) every note
  -- held in an extra slot again, an accent with no node (the retrigger
  -- accents slot 1's). One that finds no free room is refused (ruling 32)
  local function play_chord(voice_idx, event)
    local chord = chords[voice_idx]
    if not chord or not S.voices[voice_idx].active then return end
    for k = 1, chord.count do
      local slot = S.lib.notes.find(voice_idx, SEQ.note_owner, k)
      if (event.first and k > 1) or (not event.first and slot and slot > 1) then
        S.lib.notes.play(voice_idx, chord_note(voice_idx, chord, k, event.velocity, false))
      end
    end
  end

  -- Strata's own voices: a stopped voice is started at the step's first
  -- hit (a gated one is then retriggered), a running one retriggered at
  -- each hit, a gated one's gate length sent first when it changed, then
  -- the chord's further notes. Never a node for the voice's own note:
  -- start_voice for a stopped voice, retrigger for a running one. The
  -- step's locks and note are set first: a stopped voice's sends wait for
  -- its start, which carries them, so its first grain plays the step (#632)
  local function voices_play(event)
    local voice_idx = event.voice
    local voice = S.voices[voice_idx]
    local started = false
    if event.first then
      apply_step(voice_idx, event)
      if not voice.active then
        S.lib.engine_sync.start_voice(voice_idx)
        started = true
      end
    end
    if not voice.active then return end
    if not started or gated(voice_idx) then
      if gated(voice_idx) then send_gate_seconds(voice_idx, M.gate_seconds(voice_idx, event.step, event.hits)) end
      engine.retrigger(voice_idx - 1, event.velocity)
    end
    play_chord(voice_idx, event)
  end

  -- Its stop ends every voice's chord: at a pattern stop the overrides'
  -- end (end_all_overrides, first) has done it, so it finds none
  local voices_output = {name = "voices", play = voices_play, stop = function()
    for voice_idx = 1, NUM_VOICES do end_chord(voice_idx) end
  end}
  S.register_step_output(voices_output)

  -- The outputs (design 8.10) --------------------------------------------

  -- An output that failed prints once and is skipped until the next start
  -- (never the voices output: see play_outputs)
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

  -- Every output in registration order. Strata's own voices output is the
  -- exception to the protection (ruling 38): an error in it is a bug in
  -- Strata, so it is called directly and its error reaches the clock's
  -- guard, which stops the patterns and raises it again (#243, #382), as a
  -- step's error did before 3.4
  local function play_outputs(event)
    for _, output in ipairs(S.registry.step_outputs) do
      if output == voices_output then
        play_output(output, event)
      elseif not play.failed[output.name] then
        run_output(play_output, output, event)
      end
    end
  end

  -- Every output's stop, the voices output's called directly (ruling 38)
  local function stop_outputs()
    for _, output in ipairs(S.registry.step_outputs) do
      if output == voices_output then
        stop_output(output)
      elseif output.stop then
        run_output(stop_output, output)
      end
    end
  end

  -- The step's notes through the global scale, once per step (each hit's
  -- event carries a copy), or nil
  local function step_semitones(voice_idx, attrs)
    if not attrs.notes then return nil end
    local semitones = {}
    for index, degree in ipairs(attrs.notes) do semitones[index] = M.degree_semitones(voice_idx, degree) end
    return semitones
  end

  -- A hit's event (design 8.10's fields); semitones: the step's
  -- (step_semitones)
  local function hit_event(voice_idx, step, hit, hits, level, semitones)
    local attrs = S.pattern_steps[voice_idx][step] or {}
    local division = division_beats(voice_idx)
    local event = {voice = voice_idx, step = step, hit = hit, hits = hits, first = hit == 1, level = level,
      velocity = level / MAX_STEP_LEVEL, beat = clock.get_beats(), gate_beats = division / hits}
    if gated(voice_idx) then
      local steps = attrs.gate or extras(voice_idx).seq_gate_length or SEQ.gate_length_default
      event.gate_beats = steps * division / hits
    end
    if attrs.notes then event.notes, event.semitones = copy_list(attrs.notes), copy_list(semitones or {}) end
    for _, key in ipairs(SEQ.lock_keys) do
      if attrs[key] ~= nil then
        event.locks = event.locks or {}
        event.locks[key] = attrs[key]
      end
    end
    return event
  end

  -- The clocks (design 8.2, 8.13) ------------------------------------------

  -- Keep one count through a jump of the clock's beat (rulings 47, 54 and
  -- 58): the sequencer's count is the clock's beats plus play.offset, and
  -- the offset is set so the transport's pending 16th waits for the clock's
  -- first 16th at or after the moment it is due: a 16th after the
  -- transport's last, in time (the jump does not move time), or now when
  -- that has passed (a 16th within SEQ.wake_tolerance before now is now, as
  -- a wake is). Every other clock shifts by as much: at most one 16th late
  -- and never early, whether the handler keeps it at the jump or a clock
  -- notices it up to a hop later. So steps that fell together still do, 16th
  -- steps land on the clock's 16ths, no step plays twice, and the chain's
  -- and the division reset's bars and the ratchets keep their places.
  -- Raising play.generation tells every waiting clock the count moved
  function play.keep_count()
    if not S.pattern_playing then return end
    local sixteenth, state = SEQ.transport_beats, play.transport
    local now, beat_seconds = clock.get_beats(), clock.get_beat_sec()
    local since_last = (util.time() - (state.played_at or util.time())) / beat_seconds
    local due = math.max(now - SEQ.wake_tolerance, now + sixteenth - since_last)
    local first_sixteenth = math.ceil(due / sixteenth - SEQ.beat_tolerance) * sixteenth
    play.offset = state.anchor + (state.tick + 1) * sixteenth - first_sixteenth
    play.generation = play.generation + 1
  end

  -- Whether target, a beat of the sequencer's count, has come
  local function is_due(target)
    return target - play.offset <= clock.get_beats() + SEQ.flt_epsilon
  end

  -- Whether the beat has gone a 16th or more further since the
  -- participant's last sync (state.sync_time, sync_beat and
  -- sync_beat_seconds: the time, beat and beat length then) than the time
  -- gone by explains, even at the faster of the two tempos: a jump forward.
  -- A late delivery (Lua busy) moves both together, and a tempo change
  -- mid-wait never reads as one
  local function jumped_forward(state)
    local beat_seconds = math.min(state.sync_beat_seconds, clock.get_beat_sec())
    local beats, seconds = clock.get_beats() - state.sync_beat, util.time() - state.sync_time
    return beats - seconds / beat_seconds >= SEQ.late_beats
  end

  -- Whether the participant's clock was ended (state.retired: end_clock,
  -- below); its id then leaves play.retired, as the coroutine ends
  local function finished(state)
    if not state.retired then return false end
    play.retired[state.retired] = nil
    return true
  end

  -- Wait for target, a beat of the sequencer's count (the clock's beat
  -- target - play.offset), in hops of at most a 16th (SEQ.hop_beats), so a
  -- jump of the clock's beat reaches every clock within a hop. A hop lands
  -- on the clock's next 16th, or on the target once it lies within a hop:
  -- the scheduler counts a sync from the beat of the coroutine's last
  -- (state.last_sync) and lands on the first multiple of the span after it
  -- plus the offset, so an offset in (-span, 0] makes it the target itself.
  -- No clock waits on an old reference (ruling 58): before each sync it
  -- compares the beat with state.last_sync. Below it, the beat went back
  -- after its last resume was posted (a reset or a jump between the post
  -- and the delivery, or during its step) and the scheduler would count from
  -- the old beat: the count moved, and the clock keeps it unless it was kept
  -- meanwhile. A 16th or more above it (a late delivery: Lua was busy), the
  -- sync would land in the past. Either way, and after any count change
  -- (state.stale), a sleep first makes the scheduler count from now.
  -- At each wake (ruling 54) the clock tests the beat its clock.sync
  -- returned (the beat matron's tick fired it on; the live beat, which a late
  -- tick can pull back, is never the test):
  -- - from SEQ.wake_tolerance before the hop's beat to under
  --   SEQ.late_beats after it, it is on time and the step plays, late or
  --   not, whatever was kept meanwhile (a resume posted before a reset). If
  --   the beat has meanwhile gone on further than the time since its sync
  --   explains (jumped_forward: a jump forward after the post, such as a new
  --   clock source set on Lua's own thread), the count moved too: the clock
  --   keeps it unless it was kept meanwhile, and the step plays on it;
  -- - outside that the count moved: kept meanwhile (play.generation
  --   changed), or a jump no one announced (a new clock source, another
  --   script's transport handler), which this clock keeps itself, as the
  --   handler would. It then waits on the count as it is now.
  -- A target the count has already passed returns at once: the caller plays
  -- at most one step for it (rule 4). Returns true, or false when the clock
  -- was ended (end_clock, below) during its own step or while it waited
  -- (finished, above): its coroutine then ends at once, doing nothing more.
  -- state.waiting says what it waits on
  local function wait_for(state, target)
    local hop = SEQ.hop_beats
    while true do
      if finished(state) then return false end
      local now = clock.get_beats()
      if now < state.last_sync - SEQ.wake_tolerance then
        if play.generation == state.generation then play.keep_count() end
        state.stale = true
      elseif now >= state.last_sync + SEQ.late_beats then
        state.stale = true
      end
      if state.stale then
        state.waiting = "sleep"
        clock.sleep(0)
        state.waiting = nil
        if finished(state) then return false end
        now = clock.get_beats()
        state.stale, state.last_sync = false, now
      end
      local clock_target = target - play.offset
      if clock_target <= now + SEQ.flt_epsilon then return true end
      local from = state.last_sync
      local landing, offset = clock_target, 0
      if clock_target - from > hop then
        landing = math.ceil((from + SEQ.flt_epsilon) / hop) * hop  -- the clock's next 16th, as matron finds it
      else
        offset = clock_target % hop
        if offset > 0 then offset = offset - hop end
      end
      state.last_sync, state.generation = landing, play.generation
      state.sync_time, state.sync_beat, state.sync_beat_seconds = util.time(), now, clock.get_beat_sec()
      state.waiting = "sync"
      local woke = clock.sync(hop, offset) or clock.get_beats()
      state.waiting = nil
      if finished(state) then return false end
      if woke >= landing - SEQ.wake_tolerance and woke < landing + SEQ.late_beats then
        if play.generation ~= state.generation then state.stale = true end
        if jumped_forward(state) then
          -- after the post (a new clock source, set on Lua's own thread):
          -- the step plays, on the count kept now
          if play.generation == state.generation then play.keep_count() end
          state.stale = true
        end
        if landing == clock_target then return true end
      else
        if play.generation == state.generation then play.keep_count() end
        state.stale = true
      end
    end
  end

  -- Whether matron may have posted the resume of a participant's clock
  -- (state: its state) and norns not delivered it yet: while it sleeps (a
  -- sleep of 0 is due at once), once its sync's beat is near or passed
  -- (within SEQ.wake_tolerance: a tick's jitter), and whenever the beat is
  -- below the one it synced at (a reset or a new clock source has moved its
  -- sync since); and for a clock that runs now (one ending itself), which
  -- must never cancel itself
  local function resume_may_be_posted(state)
    if state.waiting ~= "sync" then return true end
    local now = clock.get_beats()
    return now < state.sync_beat or state.last_sync - now <= SEQ.wake_tolerance
  end

  -- End a participant's clock id (state: its state) without ever canceling
  -- one whose resume matron may have posted: norns would deliver that resume
  -- to a coroutine it no longer has, and clock.resume raises (maiden prints
  -- the error). Such a clock is retired instead (state.retired, and its id
  -- in play.retired): at its next wake wait_for returns false and its
  -- coroutine ends, doing nothing more. Any other is canceled at once.
  -- all_posted: the clock has just put every waiting sync on beat 0 (a
  -- followed transport start), so every resume is posted within a tick and
  -- every clock is retired
  local function end_clock(id, state, all_posted)
    state.retired = id
    if all_posted or resume_may_be_posted(state) then
      play.retired[id] = true
    else
      clock.cancel(id)
    end
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
    return k, beat
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

  -- The voice's step at its tick, and its position moved on: the position
  -- wraps at the pass's length (a length change applies at once while the
  -- position is inside it, at the wrap otherwise)
  local function take_position(voice_idx)
    local state = play.voices[voice_idx]
    local length = voice_length(voice_idx)
    if length ~= state.pass_length and state.position <= length then state.pass_length = length end
    if state.position > state.pass_length then
      state.position, state.pass_length = 1, length
      -- the wrap: with no set step left inside its length, no step of the
      -- voice will end its overrides or chord (its only set step was turned off)
      if (overrides[voice_idx] or chords[voice_idx]) and not M.has_set_step(voice_idx) then
        end_overrides(voice_idx)
      end
    end
    local step = state.position
    state.position = step + 1
    return step
  end

  -- The voice's step at its tick (take_position): a set step draws its
  -- probability once and plays its first hit; returns the hits still to
  -- play and their spacing
  local function begin_voice_step(voice_idx)
    local state = play.voices[voice_idx]
    at_beat(state.beat)
    local step = take_position(voice_idx)
    S.pattern_sounding_steps[voice_idx] = step
    local level = S.patterns[voice_idx][step]
    local hits, spacing, semitones = 0, 0, nil
    local attrs = S.pattern_steps[voice_idx][step] or {}
    local prob = attrs.prob or SEQ.max_prob
    if level > 0 and prob > 0 and (prob >= SEQ.max_prob or math.random() * SEQ.max_prob < prob) then
      -- the step's own length (a swung pair's), which the 20 ms rule reads
      local division, swing = division_beats(voice_idx), swing_beats(voice_idx)
      local step_beats = division + (state.tick % 2 == 0 and swing or -swing)
      local step_seconds = step_beats * S.lib.params_setup.beat_seconds_now()
      hits = math.min(attrs.ratchet or 1, math.max(1, math.floor(step_seconds / SEQ.min_ratchet_seconds + 1e-9)))
      spacing, semitones = step_beats / hits, step_semitones(voice_idx, attrs)
      local was_active = S.voices[voice_idx].active
      play_outputs(hit_event(voice_idx, step, 1, hits, level, semitones))
      if S.voices[voice_idx].active and not was_active then play.started = true end
    end
    finish_beat(state.beat)
    return {step = step, level = level, hits = hits, spacing = spacing, beat = state.beat, semitones = semitones}
  end

  local function play_voice_hit(voice_idx, plan, hit)
    play_outputs(hit_event(voice_idx, plan.step, hit, plan.hits, plan.level, plan.semitones))
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
    state.played_at = util.time()  -- for keep_count
    finish_beat(state.beat)
  end

  -- A clock's step through xpcall: an error forgets the clock's own id
  -- (forget), so the stop never ends this clock from inside itself,
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

  -- The voice reaches its tick k at beat (a division reset's bar puts it
  -- back at step 1, from there)
  local function take_tick(voice_idx, k, beat)
    local state = play.voices[voice_idx]
    local reset = play.reset_beat
    if reset and near(beat, reset) and state.anchor < reset - SEQ.beat_tolerance then
      state.anchor, k = reset, 0
      state.position, state.pass_length = 1, voice_length(voice_idx)
    end
    state.tick, state.beat = k, beat
  end

  -- No bursts (rule 4): at a wake the voice plays at most one step that has
  -- come. While its next tick has come too, the step at its tick is skipped
  -- (its position moves on, nothing plays) and it takes that tick, so it
  -- plays the latest, at the position the count puts it at
  local function skip_due_ticks(voice_idx)
    while true do
      local k, beat = next_voice_tick(voice_idx)
      if not is_due(beat) then return end
      take_position(voice_idx)
      take_tick(voice_idx, k, beat)
    end
  end

  -- The hit to play at a wake for hit: the latest of the step's hits that
  -- has come, or nil when the voice's next tick has come (its step's other
  -- hits are skipped)
  local function due_hit(voice_idx, plan, hit)
    local _, next_beat = next_voice_tick(voice_idx)
    if is_due(next_beat) then return nil end
    while hit < plan.hits and is_due(plan.beat + hit * plan.spacing) do hit = hit + 1 end
    return hit
  end

  -- A voice's clock from beat (its step 1 at once, its anchor): each step,
  -- its ratchets, then the wait for its next tick. Every wait is outside
  -- the guard
  local function voice_clock(voice_idx, beat)
    local state = play.voices[voice_idx]
    state.anchor, state.tick, state.beat, state.due = beat, 0, beat, nil
    state.position, state.pass_length = 1, voice_length(voice_idx)
    state.last_sync, state.generation, state.stale = clock.get_beats(), play.generation, false
    local function forget() S.pattern_clocks[voice_idx] = nil end
    local function begin() return begin_voice_step(voice_idx) end
    local plan = guarded(forget, begin)
    while true do
      local hit = 2
      while hit <= plan.hits do
        if not wait_for(state, plan.beat + (hit - 1) * plan.spacing) then return end
        hit = guarded(forget, function() return due_hit(voice_idx, plan, hit) end)
        if hit == nil then break end
        guarded(forget, function() play_voice_hit(voice_idx, plan, hit) end)
        hit = hit + 1
      end
      local next_tick = guarded(forget, function()
        local k, target = next_voice_tick(voice_idx)
        return {k = k, target = target}
      end)
      state.due = next_tick.target
      if not wait_for(state, next_tick.target) then return end
      state.due = nil
      guarded(forget, function()
        take_tick(voice_idx, next_tick.k, next_tick.target)
        skip_due_ticks(voice_idx)
      end)
      plan = guarded(forget, begin)
    end
  end

  -- Start (or start again) voice_idx's clock at beat, now: a running one
  -- is ended (end_clock) and the new one gets a state of its own
  function M.restart_voice(voice_idx, beat)
    local running = S.pattern_clocks[voice_idx]
    S.pattern_clocks[voice_idx] = nil
    if running then
      end_clock(running, play.voices[voice_idx])
      play.voices[voice_idx] = {}
    end
    S.pattern_clocks[voice_idx] = clock.run(voice_clock, voice_idx, beat)
  end

  -- The transport's clock from beat: a 16th at each wake, the latest that
  -- has come (rule 4: the 16ths skipped meanwhile move its position on)
  local function transport_clock(beat)
    local state = play.transport
    state.anchor, state.tick, state.beat, state.due = beat, 0, beat, nil
    state.last_sync, state.generation, state.stale = clock.get_beats(), play.generation, false
    local function forget() S.pattern_clock = nil end
    guarded(forget, transport_step)
    while true do
      local sixteenth = SEQ.transport_beats
      local target = state.anchor + (state.tick + 1) * sixteenth
      state.due = target
      if not wait_for(state, target) then return end
      state.due = nil
      local tick = state.tick + 1
      while is_due(state.anchor + (tick + 1) * sixteenth) do tick = tick + 1 end
      S.pattern_position = (S.pattern_position - 1 + tick - state.tick - 1) % PATTERN_LENGTH + 1
      state.tick, state.beat = tick, state.anchor + tick * sixteenth
      guarded(forget, transport_step)
    end
  end

  -- End every clock of the patterns (the voices' and the transport's:
  -- end_clock, all_posted as there), each participant on a fresh state
  local function end_clocks(all_posted)
    for voice_idx = 1, NUM_VOICES do
      local running = S.pattern_clocks[voice_idx]
      S.pattern_clocks[voice_idx], S.pattern_sounding_steps[voice_idx] = nil, nil
      if running then end_clock(running, play.voices[voice_idx], all_posted) end
      play.voices[voice_idx] = {anchor = 0, tick = 0, beat = 0, position = 1, pass_length = PATTERN_LENGTH}
    end
    local running = S.pattern_clock
    S.pattern_clock = nil
    if running then end_clock(running, play.transport, all_posted) end
    play.transport = {anchor = 0, tick = 0, beat = 0}
  end
  end_clocks()

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
  -- the steps past the length and every attribute are kept. Any whole hits
  -- and rotation: the hits clamped to 0..length, the rotation wrapped into
  -- 0..length - 1 (design 8.6), and that pair is S.seq_euclid's. Nothing
  -- while a scene recall is in progress
  function M.euclid(voice_idx, hits, rotation)
    if not valid_voice(voice_idx) or S.scene_recall_in_progress then return end
    -- whole and finite (2^53: the largest whole a float holds exactly)
    if not whole_between(hits, -2 ^ 53, 2 ^ 53) or not whole_between(rotation, -2 ^ 53, 2 ^ 53) then return end
    local length = voice_length(voice_idx)
    hits, rotation = util.clamp(hits, 0, length), rotation % length
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
  -- (key "patterns"), a stop never does; a press while the start waits
  -- takes it back (#625)
  function pattern_toggle()
    if S.pattern_playing then
      pattern_clock_stop()
    elseif not S.lib.quantize.cancel("patterns") then
      S.lib.quantize.schedule("patterns", pattern_clock_start, "play")
    end
  end

  -- Start (or start again) the patterns now: every voice and the transport
  -- at step 1 on this beat, a running chain at its first scene, and every
  -- output that failed is played again. A start the play key left waiting
  -- is dropped (a followed transport start, #625; the waiting start's own
  -- run has left the quantizer already). The clocks that ran end through
  -- end_clocks(all_posted): true for a followed transport start
  local function start_patterns(all_posted)
    S.lib.quantize.cancel("patterns")
    end_clocks(all_posted)
    -- the sequencer's count is the clock's again (ruling 47)
    play.failed, play.started, play.reset_beat, play.offset = {}, false, nil, 0
    play.generation = play.generation + 1
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

  function pattern_clock_start() start_patterns(false) end

  -- Stop the patterns: a start the play key left waiting dropped (#625),
  -- every clock ended (end_clocks), the playheads cleared, every override
  -- ended and (when they played) every output's stop run
  function pattern_clock_stop()
    S.lib.quantize.cancel("patterns")
    local was_playing = S.pattern_playing
    S.pattern_playing = false
    S.pattern_sounding_step = nil
    end_clocks(false)
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

  -- The sequencer's count less the clock's beats: 0 but after a transport
  -- start the patterns did not follow (ruling 47)
  function M.count_offset() return play.offset end

  -- A transport start the patterns do not follow (the internal clock's
  -- reset, or an external start with seq_follow_transport off) has put the
  -- clock's count back (to 0) and every waiting sync on beat 0: the count is
  -- kept through it at once (keep_count, ruling 47), and each clock, woken
  -- at once by the reset, waits again on it (wait_for). A clock whose
  -- resume matron posted before the reset was delivered before this handler
  -- (matron posts the start after the reset) and its next sync already
  -- counts from now (wait_for, ruling 58). Nothing here cancels a clock:
  -- matron posts the woken clocks' resumes within a millisecond of the
  -- reset, often before this runs, and norns would deliver each to a
  -- coroutine it no longer has (clock.resume errors). So a followed start
  -- retires every running clock (end_clock's all_posted), canceling none:
  -- each ends at its resume, within a tick, and plays nothing more
  function transport.start()
    if M.follows_transport() then
      start_patterns(true)
      request_redraw()
    else
      play.keep_count()
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

  -- Stop the pattern clocks, canceling those the stop or anything earlier
  -- left to finish at their next wake (end_clock: norns cancels every
  -- coroutine right after cleanup anyway), and give the clock its
  -- transport handlers back
  S.register_cleanup(S.constants.CLEANUP_ORDER.pattern_clock, function()
    pattern_clock_stop()
    for id in pairs(play.retired) do clock.cancel(id) end
    play.retired = {}
    if clock.transport.start == transport.start then
      clock.transport.start, transport.previous_start = transport.previous_start, nil
    end
    if clock.transport.stop == transport.stop then
      clock.transport.stop, transport.previous_stop = transport.previous_stop, nil
    end
  end)

  -- The patterns play exactly while their clocks run: the transport's and
  -- every voice's, each recorded clock a coroutine that runs (in
  -- clock.threads, as norns keeps them, and not dead) and none of them one
  -- ended and left to finish (end_clock: play.retired), which runs until
  -- its next wake, is never recorded and is forgotten when it finishes
  local function runs(id)
    local thread = clock.threads[id]
    return type(thread) == "thread" and coroutine.status(thread) ~= "dead"
  end

  local function clock_problem(id, name)
    if id == nil or not clock.threads then return nil end
    if play.retired[id] then return name .. " " .. id .. " was ended (it only waits to finish) but is recorded" end
    if not runs(id) then return name .. " " .. id .. " is not running (canceled or ended) but is recorded" end
  end

  S.register_invariant("pattern clock", function()
    for id in pairs(play.retired) do
      if clock.threads and not runs(id) then return "clock " .. id .. ", ended and left to finish, has gone but is kept" end
    end
    if S.pattern_playing ~= (S.pattern_clock ~= nil) then
      return "pattern_playing is " .. tostring(S.pattern_playing) .. " but pattern_clock is " .. tostring(S.pattern_clock)
    end
    for voice_idx = 1, NUM_VOICES do
      if S.pattern_playing ~= (S.pattern_clocks[voice_idx] ~= nil) then
        return "pattern_playing is " .. tostring(S.pattern_playing) .. " but voice " .. voice_idx .. "'s clock is "
          .. tostring(S.pattern_clocks[voice_idx])
      end
      local problem = clock_problem(S.pattern_clocks[voice_idx], "voice " .. voice_idx .. "'s clock")
      if problem then return problem end
    end
    return clock_problem(S.pattern_clock, "the transport's clock")
  end)

  return M
end

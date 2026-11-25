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
    -- 3.9 grid sequencer (design section 1, The param): v<i>_seq_gate is
    -- the step mode, 3.8's off and on (1, 2) now accent and gate, move and
    -- pulse appended; pulse the default. Its seqGate is the gate rule
    -- (gate_wanted)
    modes = {"accent", "gate", "move", "pulse"},
    gate_on = 2,                     -- the gate mode (3.8's on)
    default_mode = 4,                -- pulse
    gate_steps = {0.05, 16},         -- a gate's length in steps (the voice's and a step's)
    gate_length_default = 0.5,
    gate_release = {0.005, 4},       -- s
    gate_release_default = 0.1,
    -- 3.9 grid sequencer (design section 1): v<i>_seq_gate_floor, what a
    -- closed gate lets through (the stage's gateFloor; 0 silent, as 3.8)
    gate_floor = {0, 1, step = 0.01, default = 0},
    gate_seconds = {0.005, 120},     -- what gateSeconds may carry
    swing = {50, 75},                -- percent: 50 straight
    group_params = 10,               -- strata_seq's own (the quantizer adds PARAM_COUNT)
    max_chain_bars = 16,
    chain_defaults = {from = 1, scenes = 2, bars = 4},
    -- 3.7 (design §5.4): the chain's chances in percent, next, previous and
    -- random (S.lib.chance.pick); at the defaults it plays in order
    chain_chances = {next = 100, previous = 0, random = 0},
    max_chance = 100,
    chain_keys = {"seq_length", "seq_division", "seq_direction", "seq_misstep"},  -- what a link carries per voice
    -- 3.7 (design §5.5): v<i>_seq_direction's options (forward the default)
    -- and v<i>_seq_misstep's top, in percent
    directions = {"forward", "reverse", "ping-pong", "random"},
    forward = 1, reverse = 2, ping_pong = 3, random = 4,
    max_misstep = 100,
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
    slice_key_prefix = "slice",      -- 3.7: an overlap voice's step slice's key, "slice<step>"
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
  -- {anchor, tick, beat, due} and its position (3.7: last, the step taken
  -- last, nil at a start; taken, the steps taken in the pass; pass_length;
  -- heading, ping-pong's way, 1 or -1; 3.9's way, the direction of the
  -- step taken last, nil at a start: start_position) and the transport's
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
  -- next wake (end_clock); 4b's play.next_bar: the beat of the next bar of
  -- the count while the patterns play (nil while stopped), and
  -- play.bar_hooks: the functions on_bar registered, in order; 5b's
  -- play.last_hits: per voice, a copy of the event of the hit it played
  -- last since the patterns started (replay_hit's; emptied at every start
  -- and stop);
  -- overrides: per voice, the param ids its last played step overrides;
  -- last_played: per voice, that step; gate_sent: per voice, the
  -- gateSeconds sent last; chords: per voice, the notes its last played
  -- step plays through S.lib.notes (owner "seq", key k: the step's k-th
  -- note), {note_id, count, pitches, values} (step_chord), or nil
  local play = {voices = {}, transport = {}, failed = {}, started = false, reset_beat = nil, offset = 0,
    generation = 0, retired = {}, next_bar = nil, bar_hooks = {}, last_hits = {}}
  local overrides, last_played, gate_sent, chords = {}, {}, {}, {}
  -- 3.7 (design §3.5, ruling 32): per voice, the own region its last played
  -- step set (a voice set to one, or off), and the slice its step's first
  -- hit plays on an overlap voice once the voice has started and retriggered
  -- (and whether that region plays to an end, in one shot, where
  -- S.lib.playheads.finished ends it: step_region_to_end, #740)
  local step_regions, step_slices, step_region_to_end = {}, {}, {}
  -- the chain: the scene loaded last and the beat of the next link
  local chain = {current = nil, next_beat = nil}

  local function whole_between(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
  end

  local function number_between(value, low, high)
    return type(value) == "number" and value == value and value >= low and value <= high
  end

  local function valid_voice(voice_idx) return whole_between(voice_idx, 1, NUM_VOICES) end

  -- A number param in percent, as the menu shows it
  local function percent(param) return string.format("%d%%", param:get()) end

  local function near(a, b) return math.abs(a - b) <= SEQ.beat_tolerance end

  local function voice_param(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  local function voice_values(voice_idx) return S.voices[voice_idx].values or {} end

  local function voice_length(voice_idx) return voice_values(voice_idx).seq_length or PATTERN_LENGTH end

  local function division_beats(voice_idx)
    return SEQ.division_beats[voice_values(voice_idx).seq_division or SEQ.default_division]
  end

  -- The step mode and the gate rule (3.9 grid sequencer, design section 1;
  -- G7: one table). rule(option, voice): the seqGate a voice's mode option
  -- gives now, 1 for gate, for pulse 1 exactly while the patterns play and
  -- the voice has a set step inside its length, else 0: a function of the
  -- mode, the pattern and the transport, with nothing stored. It is the
  -- grain key's value, so the mode param's own sender sends it
  local modes = {}

  function modes.rule(option, voice_idx)
    local mode = SEQ.modes[option]
    if mode == "gate" then return 1 end
    if mode == "pulse" and S.pattern_playing and M.has_set_step(voice_idx) then return 1 end
    return 0
  end

  -- Each voice's answer now (before a change that may move it)
  function modes.answers()
    local answers = {}
    for voice_idx = 1, NUM_VOICES do answers[voice_idx] = M.gate_wanted(voice_idx) end
    return answers
  end

  -- After that change: the rule sent to each voice whose answer moved
  function modes.send_moved(answers)
    for voice_idx = 1, NUM_VOICES do
      if M.gate_wanted(voice_idx) ~= answers[voice_idx] then M.send_gate_rule(voice_idx) end
    end
  end

  -- The voice's step mode by name ("accent", "gate", "move" or "pulse"); nil
  -- for a voice out of range
  function M.step_mode(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return SEQ.modes[voice_values(voice_idx).seq_gate or SEQ.default_mode]
  end

  -- The gate rule's answer for the voice now: 0 or 1 (0 out of range)
  function M.gate_wanted(voice_idx)
    if not valid_voice(voice_idx) then return 0 end
    return modes.rule(voice_values(voice_idx).seq_gate or SEQ.default_mode, voice_idx)
  end

  -- Send the rule: the mode param through its own sender (send_param_to_
  -- engine: only to a running voice; a start sends it with its other grain
  -- keys) and nothing else. The sequencer keeps no record of what it sent
  function M.send_gate_rule(voice_idx)
    if not valid_voice(voice_idx) then return end
    send_param_to_engine(voice_param(voice_idx, "seq_gate"), voice_values(voice_idx).seq_gate or SEQ.default_mode)
  end

  local function gated(voice_idx) return M.gate_wanted(voice_idx) == 1 end

  local function direction(voice_idx) return voice_values(voice_idx).seq_direction or SEQ.forward end

  local function misstep(voice_idx) return voice_values(voice_idx).seq_misstep or 0 end

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
    cond = S.lib.conditions.valid,  -- 3.7 (design §5.3): one of the 78 conditions
    -- 3.7 (design §5.3): a slice of the voice's slot, 1 to SLICES.max
    slice = function(value) return whole_between(value, 1, S.lib.slices.SLICES.max) end,
    -- 3.9 grid sequencer (design section 2, The values): the step's value
    -- A and value B, 1 to MAX_STEP_LEVEL (S.lib.lanes.value)
    va = function(value) return whole_between(value, 1, MAX_STEP_LEVEL) end,
    vb = function(value) return whole_between(value, 1, MAX_STEP_LEVEL) end,
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

  -- The one writer of a step's level (3.9 grid sequencer, design section 1:
  -- the grid's level gesture, SEQ's encoder, its level and reset rows, the
  -- arc's ring and toggle_pattern_step write through it; replace_pattern
  -- writes a whole pattern): a whole level 0..MAX_STEP_LEVEL, the voice's
  -- pattern undo ended, the gate rule sent when its answer moved, the grid
  -- redrawn. A voice, step or level out of range does nothing
  function M.set_level(voice_idx, step, level)
    if not valid_place(voice_idx, step) or not whole_between(level, 0, MAX_STEP_LEVEL) then return end
    local answer = M.gate_wanted(voice_idx)
    S.patterns[voice_idx][step] = level
    S.lib.mutation.note_pattern_edit(voice_idx)
    if M.gate_wanted(voice_idx) ~= answer then M.send_gate_rule(voice_idx) end
    grid_redraw()
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

  -- Every voice's step attributes from a (valid) steps block, but those of
  -- the voices in skip (a set by voice, apply_entries': a fade's released
  -- voices keep theirs, #1050)
  local function set_all_steps(steps, skip)
    local copy = copy_steps(steps)
    for voice_idx = 1, NUM_VOICES do
      if not (skip and skip[voice_idx]) then S.pattern_steps[voice_idx] = copy[voice_idx] end
    end
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

  -- 3.7: the own region the voice's last played step set ends (unless
  -- another note has set its own since)
  local function end_step_region(voice_idx)
    local region = step_regions[voice_idx]
    step_regions[voice_idx], step_region_to_end[voice_idx] = nil, nil
    local own = region and S.lib.notes.own_region(voice_idx)
    if own and own[1] == region[1] and own[2] == region[2] then S.lib.notes.set_own_region(voice_idx, nil) end
  end

  -- 3.7 (2b's second review): the own region the voice's last played step
  -- set, a copy, while it sounds: still the own region, the voice running,
  -- and in one shot not yet played out (S.lib.playheads.finished: the
  -- scan's own end, so a restart of the scan names it again, #740); else
  -- nil. S.lib.slices.playing names it (no slot-1 record holds a step's
  -- slice)
  function M.playing_region(voice_idx)
    local region = valid_voice(voice_idx) and step_regions[voice_idx]
    if not region or not S.voices[voice_idx].active then return nil end
    local own = S.lib.notes.own_region(voice_idx)
    if not (own and own[1] == region[1] and own[2] == region[2]) then return nil end
    if step_region_to_end[voice_idx] and S.lib.playheads.finished(voice_idx) then return nil end
    return {region[1], region[2]}
  end

  -- 3.7: whether a note is a step's slice on an overlap voice (its key
  -- "slice<step>")
  local function step_slice_note(owner, key)
    local prefix = SEQ.slice_key_prefix
    return owner == SEQ.note_owner and type(key) == "string" and key:sub(1, #prefix) == prefix
  end

  -- 3.7: the voice's step slices that do not play to their end (wrap,
  -- bounce, a scan of 0) are released; one-shot ones ring on (their time
  -- ends them, S.lib.notes)
  local function release_step_slices(voice_idx)
    for _, used in ipairs(S.lib.notes.slots(voice_idx)) do
      if used.held and step_slice_note(used.owner, used.key) then S.lib.notes.release(voice_idx, used.owner, used.key) end
    end
  end

  -- The values a voice's hits hold (3.9 grid sequencer, package 2a, design
  -- section 2, The values; G7: one table of functions). held_values[v]:
  -- per target, {level, step (the step that set it), param (the param id
  -- its override is on)}, or nil with none. A value is a base override, as
  -- a lock is, kept apart from `overrides` (the last played step's locks
  -- and note): it stays through steps without one and ends only at the
  -- ends of design section 2. A lock on its param wins for the lock's step
  -- (the override is the lock's while overrides[v] names the param), and
  -- when the lock ends the value is set again
  local held_values = {}
  local values = {}

  -- The voice's held value on a param (its value now, from its level), or nil
  function values.on_param(voice_idx, param_id)
    for target, entry in pairs(held_values[voice_idx] or {}) do
      if entry.param == param_id then
        local _, value = S.lib.lanes.value(voice_idx, target, entry.level)
        return value
      end
    end
    return nil
  end

  -- A lock or note override of the voice's ends: the param takes the held
  -- value on it again, or its own value
  function values.release(voice_idx, param_id)
    local value = values.on_param(voice_idx, param_id)
    if value ~= nil then set_override(voice_idx, param_id, value) else clear_override(voice_idx, param_id) end
  end

  -- End the voice's held values that keep(entry, target) does not keep (all with
  -- no keep): each override cleared, the param back to its own value, but
  -- where a lock of the last played step holds the param, which stays the
  -- lock's until it ends (it then finds no value to bring back)
  function values.end_held(voice_idx, keep)
    local held = held_values[voice_idx]
    if not held then return end
    for _, target in ipairs(sorted_keys(held)) do
      local entry = held[target]
      if not (keep and keep(entry, target)) then
        held[target] = nil
        if not (overrides[voice_idx] and overrides[voice_idx][entry.param]) then clear_override(voice_idx, entry.param) end
      end
    end
    if next(held) == nil then held_values[voice_idx] = nil end
  end

  -- The step's own level on a target (lane A's or B's read at the step's
  -- tick, whichever names it now: S.lib.lanes.last_read, 2c), or nil
  function values.step_level(voice_idx, target)
    for _, lane in ipairs({"a", "b"}) do
      if S.lib.lanes.target(voice_idx, lane) == target then return S.lib.lanes.last_read(voice_idx, lane) end
    end
    return nil
  end

  -- 2b: the pitch level a played step stands on, which its notes count
  -- from: the step's own pitch value, unless a MIDI key down keeps the
  -- voice's own note (the value gives way: values.take sets nothing), else
  -- the held one; nil with neither. values.midi_keeps_own is
  -- other_owns_slot_1, set where that is defined
  function values.pitch_level(voice_idx)
    local level = values.step_level(voice_idx, "pitch")
    if level and not values.midi_keeps_own(voice_idx) then return level end
    return M.held_value(voice_idx, "pitch")
  end

  -- A played step's values (its first hit): each of lanes A and B whose
  -- target is set and whose read at the step's tick holds a value (2c:
  -- S.lib.lanes.last_read) replaces the voice's held value on that
  -- target, but for a pitch value while a MIDI key down keeps the voice's
  -- own note (2b: it gives way). Returns the params they set, param id ->
  -- value, to be sent where no lock of the step holds them
  function values.take(voice_idx, step)
    local fresh = {}
    for _, lane in ipairs({"a", "b"}) do
      local target = S.lib.lanes.target(voice_idx, lane)
      local level = target and S.lib.lanes.last_read(voice_idx, lane)
      if level and target == "pitch" and values.midi_keeps_own(voice_idx) then level = nil end
      local param_id, value
      if level then param_id, value = S.lib.lanes.value(voice_idx, target, level) end
      if param_id then
        held_values[voice_idx] = held_values[voice_idx] or {}
        held_values[voice_idx][target] = {level = level, step = step, param = param_id}
        fresh[param_id] = value
      end
    end
    return fresh
  end

  -- 5b: a rolled hit sets the voice's held values again (each at its
  -- level's value now), but where a lock of the last played step holds the
  -- param, which stays the lock's
  function values.set_again(voice_idx)
    local held = held_values[voice_idx]
    for _, target in ipairs(sorted_keys(held or {})) do
      local entry = held[target]
      local param_id, value = S.lib.lanes.value(voice_idx, target, entry.level)
      if param_id == entry.param and not (overrides[voice_idx] and overrides[voice_idx][param_id]) then
        set_override(voice_idx, param_id, value)
      end
    end
  end

  -- The level the voice's hits hold on a target (one of S.lib.lanes.TARGETS), or nil
  function M.held_value(voice_idx, target)
    local entry = valid_voice(voice_idx) and held_values[voice_idx] and held_values[voice_idx][target]
    return entry and entry.level or nil
  end

  -- Every held value of the voice ends (a target, mode, source or type
  -- change: an auto target and pitch's path follow the source and type)
  function M.end_held_values(voice_idx)
    if valid_voice(voice_idx) then values.end_held(voice_idx) end
  end

  -- The voice's held value on one target ends (fix round 1: a jump,
  -- S.lib.positions.jump, ends a held position value, so the jump is heard)
  function M.end_held_value(voice_idx, target)
    if not valid_voice(voice_idx) then return end
    values.end_held(voice_idx, function(_, held_target) return held_target ~= target end)
  end

  -- fx2 (#1047, the maintainer's rule): every set of a voice param the
  -- sequencer does not make ends the voice's held value on that param, as
  -- a hand edit does, so the set value is heard: a morph, a transition,
  -- OSC, a MIDI map, a mutation step, a randomize. The param's own action
  -- calls it (lib/params_setup.lua's add_voice_param), and norns runs an
  -- action only when the value changes, so a sync, which sends the stored
  -- value without setting it, ends nothing. The sequencer never sets a
  -- held param (its values and locks are base overrides). The drift's
  -- writes (S.drift_writing) end nothing: the script's own wander walks
  -- under the value, as an LFO never sets its destination (the
  -- controller's ruling). A lock of the last played step on the param
  -- keeps its step (values.end_held)
  function M.param_set(voice_idx, param_id)
    if S.drift_writing or not (valid_voice(voice_idx) and held_values[voice_idx]) then return end
    values.end_held(voice_idx, function(entry) return entry.param ~= param_id end)
  end

  -- A hand edit of a param ends the held value on it: the engine sync's
  -- own touch hook has cleared its override already, so the record goes
  -- with it and nothing is sent
  S.register_param_touch(function(param_id)
    for voice_idx = 1, NUM_VOICES do
      for target, entry in pairs(held_values[voice_idx] or {}) do
        if entry.param == param_id then held_values[voice_idx][target] = nil end
      end
      if held_values[voice_idx] and next(held_values[voice_idx]) == nil then held_values[voice_idx] = nil end
    end
  end)

  -- End every override a voice's step set, and its chord: each param goes
  -- back to its stored value at once. Its held values end too, but with
  -- keep_held (a length cut past the last played step, not past theirs),
  -- where a held value comes back on a lock's param
  local function end_overrides(voice_idx, keep_held)
    step_slices[voice_idx] = nil
    end_step_region(voice_idx)
    release_step_slices(voice_idx)
    end_chord(voice_idx)
    if not keep_held then values.end_held(voice_idx) end
    local held = overrides[voice_idx]
    overrides[voice_idx], last_played[voice_idx] = nil, nil
    if not held then return end
    for _, param_id in ipairs(sorted_keys(held)) do values.release(voice_idx, param_id) end
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
  -- grain_pitch) as the note a MIDI note plays at that rate (rate 1 at
  -- S.lib.samples.rate_root: a buffer voice's file's key, else 60)
  local function value_note(voice_idx, value)
    if voice_uses_synth(voice_idx) then return SEQ.a4_note + SEQ.semitones * log2(value / SEQ.a4_freq) end
    return S.lib.samples.rate_root(voice_idx) + SEQ.semitones * log2(value)
  end

  -- The voice's own pitch as a (fractional) note: its note param's stored value's
  local function voice_pitch_note(voice_idx) return value_note(voice_idx, params:get(note_param(voice_idx))) end

  -- The semitones from the voice's pitch to its k-th tone above (below, for
  -- a negative k) among the tuning's allowed tones (S.lib.tuning: the
  -- scale's in twelve tones to an octave, every tone otherwise), the root
  -- included; 0 for degree 0. Where the allowed tones are an equal division
  -- (the scale off in twelve equal steps, 19 equal, ...) a degree is k
  -- steps from the voice's own pitch, so a voice tuned between two tones
  -- keeps its tuning (3.8 ruling 40)
  function M.degree_semitones(voice_idx, k)
    if not valid_voice(voice_idx) or not whole_between(k, -SEQ.max_degree, SEQ.max_degree) then return nil end
    if k == 0 then return 0 end
    local tuning = S.lib.tuning
    local step = tuning.equal_step()
    if step then return k * step end
    local pitch = voice_pitch_note(voice_idx)
    return tuning.step(pitch, k) - pitch
  end

  -- The voices output (design 8.3) ---------------------------------------

  -- Send a voice's gate length, only when it differs from the one sent last
  local function send_gate_seconds(voice_idx, seconds)
    if gate_sent[voice_idx] == seconds then return end
    gate_sent[voice_idx] = seconds
    engine.setGrainParam(voice_idx - 1, "gateSeconds", seconds)
  end

  -- A step's gate in seconds: the step's gate (or the voice's length) in
  -- steps x the voice's nominal step in seconds / hits, clamped. With a
  -- step (a hit's), its gate is the gate lane's read at the step's tick
  -- (2c: S.lib.lanes.last_read, the step's own key while the lane follows)
  function M.gate_seconds(voice_idx, step, hits)
    if not valid_voice(voice_idx) then return nil end
    local steps = (step and S.lib.lanes.last_read(voice_idx, "gate")) or voice_values(voice_idx).seq_gate_length
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
  values.midi_keeps_own = other_owns_slot_1

  -- 2b: the param a note transposes (note_param) and its value at the
  -- voice's own pitch moved by a whole number of degrees, -SEQ.max_degree
  -- to SEQ.max_degree (degree_semitones: the tuning's steps), clamped to
  -- the param's range, as a step's note sets it; nil out of range or not
  -- finite
  function M.note_value(voice_idx, degrees)
    local semitones = M.degree_semitones(voice_idx, degrees)
    if semitones == nil then return nil end
    local note_id = note_param(voice_idx)
    local low, high = param_range(note_id)
    local value = params:get(note_id) * 2 ^ (semitones / SEQ.semitones)
    if not finite(value) then return nil end
    return note_id, util.clamp(value, low, high)
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
      quiet = own, extra_only = not own, region = chord.region,  -- 3.7: the step's slice, on every note
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
    elseif values.on_param(voice_idx, note_id) ~= nil then
      values.release(voice_idx, note_id)  -- 2b: a held pitch value plays again
    elseif overrides[voice_idx] and overrides[voice_idx][note_id] then
      clear_override(voice_idx, note_id)
    end
  end

  -- The reviewer's minor 2: a MIDI note took the voice's own note from the
  -- step's (branch 6: the voice's cap or the pool full; lib/midi_in.lua
  -- calls this when its note lands on slot 1). The step's note override
  -- ends at once, as for a first note that is not the voice's own, so MIDI's
  -- pitch plays now rather than at the next step. Nothing when the step's
  -- first note was not the voice's own or still is. 2b: a held pitch value
  -- gives way first (it ends; the next hit that sets one brings it back)
  function M.own_note_taken(voice_idx)
    if not valid_voice(voice_idx) then return end
    M.end_held_value(voice_idx, "pitch")
    local chord = chords[voice_idx]
    if not (chord and chord.own) or S.lib.notes.find(voice_idx, SEQ.note_owner, 1) == 1 then return end
    chord.own = false
    end_note_override(voice_idx, chord.note_id, chord.lock_value)
    local held = overrides[voice_idx]
    if held and chord.lock_value == nil then
      held[chord.note_id] = nil
      if next(held) == nil then overrides[voice_idx] = nil end
    end
  end

  -- A step's inputs (3.6): its locks (a table, never nil), the values they
  -- want (param id -> value) and their ids, and its chord (step_chord, nil
  -- without notes). Worked out once per step, at its begin, so the hits'
  -- pitches and what the voices output plays come from the one chord
  local stepping = {}  -- per voice: the inputs of the step being begun, until its first hit's apply_step
  -- 2b: pitch_level, the pitch value the step stands on (values.pitch_level),
  -- gives pitch_value, its value on the note param, or nil
  local function step_inputs(voice_idx, locks, semitones, pitch_level)
    locks = locks or {}
    local wanted, lock_ids = {}, {}  -- param id -> value: the locks, then the note
    for _, key in ipairs(SEQ.lock_keys) do
      if SEQ.lock_params[key] and locks[key] ~= nil then
        local param_id = voice_param(voice_idx, SEQ.lock_params[key])
        wanted[param_id] = locks[key]
        lock_ids[#lock_ids + 1] = param_id
      end
    end
    local pitch_value
    if pitch_level then pitch_value = select(2, S.lib.lanes.value(voice_idx, "pitch", pitch_level)) end
    return {locks = locks, wanted = wanted, lock_ids = lock_ids, chord = step_chord(voice_idx, semitones, wanted),
      pitch_value = pitch_value}
  end

  -- A step's absolute pitches (fractional MIDI notes): its chord's, else
  -- the voice's own pitch (a lock on the note param, else, 2b, the pitch
  -- value the step stands on, else the stored value), both after the
  -- step's pitch lock. On an input
  -- voice the lock is on the note's own param, so it is in the chord's base
  -- already; on a synth or buffer voice it is on v<i>_grain_pitch (a rate
  -- ratio), and every pitch moves by the lock's distance from the standing
  -- grain pitch, 12 x log2(lock / stored) semitones (the standing grain
  -- pitch itself is not added: unlocked, nothing moves). A fresh list
  local function step_pitches(voice_idx, inputs)
    local pitches, chord = {}, inputs.chord
    local note_id = note_param(voice_idx)
    if chord then
      for k = 1, chord.count do
        if chord.pitches[k] ~= nil then pitches[#pitches + 1] = chord.pitches[k] end
      end
    else
      pitches[1] = value_note(voice_idx, inputs.wanted[note_id] or inputs.pitch_value or params:get(note_id))
    end
    local pitch_id = voice_param(voice_idx, SEQ.lock_params.pitch)
    local lock = inputs.wanted[pitch_id]
    if pitch_id ~= note_id and lock ~= nil then
      local shift = SEQ.semitones * log2(lock / params:get(pitch_id))
      if finite(shift) then
        for index, pitch in ipairs(pitches) do pitches[index] = pitch + shift end
      end
    end
    return pitches
  end

  -- A step's first hit on a voice: the locks, the bookmark and the note, as
  -- base overrides; the previous played step's overrides this one lacks
  -- end, and its chord's notes this one lacks are released (by key: a note
  -- it keeps is played again in place). The first note plays here, where
  -- 3.4 set its override: the voice's own (slot 1) as that override, or,
  -- while another owner holds slot 1, only an extra note in free room
  -- (ruling 35), with no note override
  local function apply_step(voice_idx, event)
    -- the step's locks, wanted values and chord, worked out once at the
    -- step's begin (begin_voice_step: its events' pitches come from them)
    local step = stepping[voice_idx]
      or step_inputs(voice_idx, event.locks, event.semitones, values.pitch_level(voice_idx))
    stepping[voice_idx] = nil
    local locks, wanted, lock_ids, chord = step.locks, step.wanted, step.lock_ids, step.chord
    local note_id = chord and chord.note_id
    local lock_value = note_id and wanted[note_id]  -- an input voice's pitch lock, the note's own param
    if note_id then wanted[note_id] = chord.values[1] end
    for k = (chord and chord.count or 0) + 1, SEQ.max_step_notes do
      S.lib.notes.release(voice_idx, SEQ.note_owner, k)
    end
    -- 3.9 (design section 2): the step's values replace the held ones on
    -- their targets; an override of the last step this one lacks ends, its
    -- param back to a held value on it (the lock's end: the value comes
    -- back) or to its own; a value is sent where no lock of this step
    -- holds its param (the lock wins for its step), and a held value this
    -- step does not set is not sent again (it stays)
    local fresh = values.take(voice_idx, event.step)
    for _, param_id in ipairs(sorted_keys(overrides[voice_idx] or {})) do
      if wanted[param_id] == nil and fresh[param_id] == nil then values.release(voice_idx, param_id) end
    end
    for _, param_id in ipairs(lock_ids) do
      if param_id ~= note_id then set_override(voice_idx, param_id, wanted[param_id]) end
    end
    for _, param_id in ipairs(sorted_keys(fresh)) do
      if wanted[param_id] == nil then set_override(voice_idx, param_id, fresh[param_id]) end
    end
    local n = locks.bookmark
    if n and S.lib.bookmarks.is_set(voice_idx, n) and bookmark_in_loop(voice_idx, n) then
      S.lib.bookmarks.recall(voice_idx, n)
    end
    -- 3.7 (design §3.5, ruling 32): the step's slice, when the voice's slot
    -- has it. On a voice set to one, or off, it is the own note's region
    -- (before the start or the retrigger: no node), shared by the chord. On
    -- an overlap voice the own note comes first, as on one (decision 23,
    -- the final review's I-2); the slice plays in a slot of its own after
    -- them (voices_play) only while another owner holds slot 1 or, with no
    -- chord, while an earlier step's slice still rings on the own note to
    -- its end: then the step's hits are its slice's (rings), so that slice
    -- is never restarted and the own note never plays the loop under it. A
    -- played step without one ends the last one's region. As the chord's
    -- first note, the region gives way while another owner holds slot 1 (a
    -- MIDI key down). Each step's slice is a hit: it is sent even when it is
    -- the same, so its scan restarts (the chord's own note sends it through
    -- play_own, as a hit too)
    local region = event.slice and S.lib.slices.voice_region(voice_idx, event.slice)
    local overlap = region and S.lib.slices.option(voice_idx) == "overlap"
    local others = (note_id or region) and other_owns_slot_1(voice_idx)
    local rings = overlap and not chord and not others and step_region_to_end[voice_idx] == true
      and M.playing_region(voice_idx) ~= nil
    local extra = overlap and (others or rings)
    if others and not extra then region = nil end
    release_step_slices(voice_idx)
    step_slices[voice_idx] = extra and {slice = event.slice, step = event.step, rings = rings} or nil
    if region and not extra then
      if not chord then S.lib.notes.set_own_region(voice_idx, region, true) end
      step_regions[voice_idx] = region
      step_region_to_end[voice_idx] = S.lib.notes.pass_seconds(voice_idx, region[2]) ~= nil
    elseif not rings then
      end_step_region(voice_idx)
    end
    if chord then chord.region = not extra and region or nil end
    chords[voice_idx] = chord
    local own = note_id and not others
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

  -- #744: an overlap voice's step slice that finds no extra slot (the pool
  -- at 0 or full, or a ratchet's slice note gone) takes the own note with
  -- its own slice, as on a voice set to one, before the retrigger; the
  -- step's later hits are then the own note's
  local function take_own_slice(voice_idx, n)
    step_slices[voice_idx] = nil
    local region = S.lib.slices.voice_region(voice_idx, n)
    if not region then return end
    S.lib.notes.set_own_region(voice_idx, region, true)
    step_regions[voice_idx] = region
    step_region_to_end[voice_idx] = S.lib.notes.pass_seconds(voice_idx, region[2]) ~= nil
  end

  -- A move voice's hit (3.9 grid sequencer, design section 1, A move hit):
  -- for its own voice a copy of the event at velocity 0, so it adds no swell
  -- and plucks no string (the retrigger still reaches what listens to hits);
  -- any other mode's event as it is, and a rolled hit (5b) too: it swells
  -- at its level in every mode
  function modes.own_event(event)
    if event.rolled or M.step_mode(event.voice) ~= "move" then return event end
    local own = {}
    for key, value in pairs(event) do own[key] = value end
    own.velocity = 0
    return own
  end

  -- Strata's own voices: a stopped voice is started at the step's first
  -- hit (a gated one is then retriggered), a running one retriggered at
  -- each hit, a gated one's gate length sent first when it changed, then
  -- the chord's further notes. Never a node for the voice's own note:
  -- start_voice for a stopped voice, retrigger for a running one. The
  -- step's locks and note are set first: a stopped voice's sends wait for
  -- its start, which carries them, so its first grain plays the step (#632).
  -- 3.9: a move voice plays its own hit at velocity 0 (modes.own_event).
  -- 5b: a rolled hit (replay_hit) is a later hit, so it plays no step
  -- again: it sets the held values again first, and a gated voice's gate
  -- length is the event's own (the roll's interval times the voice's)
  local function voices_play(event)
    event = modes.own_event(event)
    local voice_idx = event.voice
    local voice = S.voices[voice_idx]
    local started = false
    if event.first then
      apply_step(voice_idx, event)
      if not voice.active then
        -- a gated voice's start is followed by its retrigger: one hit
        S.lib.engine_sync.start_voice(voice_idx, {retrigger_follows = gated(voice_idx)})
        started = true
      end
    end
    if not voice.active then return end
    -- 3.7: an overlap voice's step slice in a slot of its own (apply_step);
    -- while the own note's slice rings (rings) every hit of the step is the
    -- slice's, never a retrigger
    local slice = step_slices[voice_idx]
    if slice and slice.step ~= event.step then slice = nil end
    local on_slice = slice and slice.rings
    local gate_seconds
    if event.rolled then values.set_again(voice_idx) end
    if not started or gated(voice_idx) then
      if gated(voice_idx) then
        gate_seconds = event.gate_seconds or M.gate_seconds(voice_idx, event.step, event.hits)
        send_gate_seconds(voice_idx, gate_seconds)
      end
      if not on_slice then S.lib.engine_sync.retrigger(voice_idx, event.velocity, "step", gate_seconds) end
    end
    play_chord(voice_idx, event)
    -- with no room the voice's oldest step slice is cut and its slot taken
    -- (never another owner's); it rings past the next step. A later hit (a
    -- ratchet) of a step whose hits are its slice's plays it again in its
    -- slot; one refused a slot, or whose note is gone (stolen), takes the
    -- own note with its slice and retriggers it (#744)
    if slice and (event.first or on_slice) then
      local key = SEQ.slice_key_prefix .. event.step
      local slot = (event.first or S.lib.notes.find(voice_idx, SEQ.note_owner, key))
        and S.lib.slices.play(voice_idx, slice.slice, {owner = SEQ.note_owner, key = key, velocity = event.velocity,
          park = false, extra_only = true, steals = step_slice_note})
      if on_slice and slot then
        S.lib.engine_sync.extra_note_hit(voice_idx, slot, event.velocity, gate_seconds, "step")
      elseif on_slice then
        take_own_slice(voice_idx, slice.slice)
        S.lib.engine_sync.retrigger(voice_idx, event.velocity, "step", gate_seconds)
      end
    end
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

  -- 5b: a copy of a hit's event, its lists and locks copied too, so no
  -- output's change to one reaches the other
  function play.copy_event(event)
    local copy = {}
    for key, value in pairs(event) do copy[key] = value end
    for _, key in ipairs({"pitches", "notes", "semitones"}) do
      if type(event[key]) == "table" then copy[key] = copy_list(event[key]) end
    end
    if type(event.locks) == "table" then
      copy.locks = {}
      for key, value in pairs(event.locks) do copy.locks[key] = value end
    end
    return copy
  end

  -- Every output in registration order (5b: a step's hit kept first, a
  -- copy, for replay_hit). Strata's own voices output is the
  -- exception to the protection (ruling 38): an error in it is a bug in
  -- Strata, so it is called directly and its error reaches the clock's
  -- guard, which stops the patterns and raises it again (#243, #382), as a
  -- step's error did before 3.4
  local function play_outputs(event)
    if not event.rolled then play.last_hits[event.voice] = play.copy_event(event) end
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
  -- event carries a copy), or nil. 2b: counted from the pitch value the
  -- step stands on (pitch_level; 8 is the voice's own pitch), the sum
  -- clipped to -SEQ.max_degree..SEQ.max_degree; on an input voice a pitch
  -- lock is on the note's own param and wins for its step, so the value
  -- adds nothing there
  local function step_semitones(voice_idx, attrs, pitch_level)
    if not attrs.notes then return nil end
    local offset = pitch_level and pitch_level - S.lib.lanes.MOVE.own_pitch_level or 0
    if attrs.pitch ~= nil and note_param(voice_idx) == voice_param(voice_idx, SEQ.lock_params.pitch) then offset = 0 end
    local semitones = {}
    for index, degree in ipairs(attrs.notes) do
      semitones[index] = M.degree_semitones(voice_idx, util.clamp(degree + offset, -SEQ.max_degree, SEQ.max_degree))
    end
    return semitones
  end

  -- A step's locks as a fresh table (a subset of SEQ.lock_keys), nil when none is set
  local function step_locks(attrs)
    local locks
    for _, key in ipairs(SEQ.lock_keys) do
      if attrs[key] ~= nil then
        locks = locks or {}
        locks[key] = attrs[key]
      end
    end
    return locks
  end

  -- A hit's event (design 8.10's fields); semitones: the step's
  -- (step_semitones); pitches (3.6): the step's (step_pitches), a copy per event
  local function hit_event(voice_idx, step, hit, hits, level, semitones, pitches)
    local attrs = S.pattern_steps[voice_idx][step] or {}
    local division = division_beats(voice_idx)
    local event = {voice = voice_idx, step = step, hit = hit, hits = hits, first = hit == 1, level = level,
      velocity = level / MAX_STEP_LEVEL, beat = clock.get_beats(), gate_beats = division / hits,
      pitches = copy_list(pitches)}
    -- 3.9: outside, a move hit is at full velocity (its level is kept)
    if M.step_mode(voice_idx) == "move" then event.velocity = 1 end
    if gated(voice_idx) then
      -- 2c: the gate lane's read at the step's tick
      local steps = S.lib.lanes.last_read(voice_idx, "gate") or voice_values(voice_idx).seq_gate_length
        or SEQ.gate_length_default
      event.gate_beats = steps * division / hits
    end
    if attrs.notes then event.notes, event.semitones = copy_list(attrs.notes), copy_list(semitones or {}) end
    event.locks = step_locks(attrs)
    event.slice = attrs.slice  -- 3.7: the step's slice (design §5.3)
    return event
  end

  -- The voice's nominal step in seconds (its division at the tempo now),
  -- or nil for no voice
  function M.step_seconds(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return division_beats(voice_idx) * S.lib.params_setup.beat_seconds_now()
  end

  -- 5b (design section 4, R1 to R4): the voice's last played hit again,
  -- through every step output, as a later hit of its step (first false,
  -- rolled true: it plays no step again, so the step's locks, note and
  -- chord stand as held and its extra notes are heard again), at the hit's
  -- level as its velocity in every mode (move too: a rolled hit swells),
  -- at the beat now; its gate the roll's interval (S.lib.loop_roll's, the
  -- voice's step with no roll) times the voice's gate length in steps.
  -- Never a node. false, playing nothing, with the patterns stopped or
  -- when the voice has played no hit since they started
  function M.replay_hit(voice_idx)
    if not valid_voice(voice_idx) or not S.pattern_playing then return false end
    local kept = play.last_hits[voice_idx]
    if kept == nil then return false end
    local event = play.copy_event(kept)
    local seconds = S.lib.loop_roll.interval(voice_idx) or M.step_seconds(voice_idx)
    local beats = seconds / S.lib.params_setup.beat_seconds_now()
    event.first, event.rolled, event.beat = false, true, clock.get_beats()
    event.velocity, event.gate_beats, event.gate_seconds = event.level / MAX_STEP_LEVEL, beats, nil
    if gated(voice_idx) then
      local steps = voice_values(voice_idx).seq_gate_length or SEQ.gate_length_default
      event.gate_beats = steps * beats
      event.gate_seconds = util.clamp(steps * seconds, SEQ.gate_seconds[1], SEQ.gate_seconds[2])
    end
    play_outputs(event)
    return true
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
    -- SETUP shows the offset (#921), whoever kept the count: the handler or
    -- the first clock that noticed a jump nobody announced
    request_redraw()
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
    local swing = voice_values(voice_idx).seq_swing or SEQ.swing[1]
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

  -- The scene the chain links next from current, and the move (3.7, design
  -- §5.4; the groundwork's stepper): S.lib.scenes.next_slot over the
  -- playable slots (populated and valid) of seq_chain_scenes from
  -- seq_chain_from, by seq_chain_next, seq_chain_previous and
  -- seq_chain_random. With no current scene (a start, the chain switched
  -- on), or a current one cleared or made invalid since, the first playable
  -- slot after it, with no draw (#738: an invalid scene is never drawn, so
  -- no walk goes on from one). nil with none
  local function next_chain_scene(current)
    local scenes = S.lib.scenes
    return scenes.next_slot(current, scenes.playable_slots(params:get("seq_chain_from"), params:get("seq_chain_scenes")),
      {params:get("seq_chain_next"), params:get("seq_chain_previous"), params:get("seq_chain_random")})
  end

  -- A link: the scene's patterns, steps, lanes and variations blocks and each voice's length,
  -- division, direction and misstep, and nothing else; every override ends
  local function load_chain_scene(slot)
    local data = S.scenes[slot].data
    chain.current = slot
    end_all_overrides()
    for voice_idx = 1, NUM_VOICES do M.replace_pattern(voice_idx, data.patterns[voice_idx]) end
    S.lib.lanes.apply_block(data.lanes or {})  -- 2c: the lanes block before the steps block, as a recall
    set_all_steps(data.steps or {})
    S.lib.pattern_letters.apply_block(data.variations or {})  -- 4a: the letters (a copy: the scene keeps its own)
    for voice_idx = 1, NUM_VOICES do
      local scene_values = data.voices[voice_idx].values or {}
      for _, key in ipairs(SEQ.chain_keys) do
        if scene_values[key] then params:set(voice_param(voice_idx, key), scene_values[key]) end
      end
    end
  end

  -- Every move but a repeat links its slot, the one playing too (ruling 36).
  -- periods (#1051): the chain periods that passed, 1 but after a late
  -- wake; the place moves on a move a period, and the slot it reaches is
  -- linked once, unless every move was a repeat (those between never load).
  -- True when it linked
  local function chain_link(periods)
    local place, linked = chain.current, false
    for _ = 1, periods or 1 do
      local slot, move = next_chain_scene(place)
      if not slot then break end
      place, linked = slot, linked or move ~= "repeat"
    end
    if linked then load_chain_scene(place) end
    return linked
  end

  -- 4b: every bar hook, in the order registered (first: the patterns'
  -- start, its own bar; bars: the bars of the count that passed, 1 but
  -- after a late wake)
  function play.run_bar_hooks(first, bars)
    for _, fn in ipairs(play.bar_hooks) do fn(first, bars) end
  end

  -- Whatever falls on a beat before its steps: a chain link due then (the
  -- first participant to reach it links, for all), once however late the
  -- beat, moved on by the periods that passed (#1051), then, at a bar of the
  -- count (4b), the bar hooks: once however late the beat (the participant's
  -- beat, the one its clock.sync returned, moved on to the latest step that
  -- has come), told how many bars passed (review round 1). A link clears
  -- what the hooks keep (the letters' waits and places), so after one the
  -- bars counted are those from the link's own bar (#1051's review round
  -- 1), and a late wake lands where on-time play would have
  local function at_beat(beat)
    local linked_at = nil
    if chain.next_beat and beat >= chain.next_beat - SEQ.beat_tolerance then
      local period, periods = params:get("seq_chain_bars") * SEQ.bar_beats, 0
      while beat >= chain.next_beat - SEQ.beat_tolerance do
        chain.next_beat, periods = chain.next_beat + period, periods + 1
      end
      if chain_link(periods) then linked_at = chain.next_beat - period end
    end
    if play.next_bar and beat >= play.next_bar - SEQ.beat_tolerance then
      local bars = 0
      while beat >= play.next_bar - SEQ.beat_tolerance do
        if not (linked_at and play.next_bar < linked_at - SEQ.beat_tolerance) then bars = bars + 1 end
        play.next_bar = play.next_bar + SEQ.bar_beats
      end
      if bars > 0 then play.run_bar_hooks(false, bars) end
    end
  end

  -- 3.9 grid sequencer (4b): fn(first, bars) is called at each bar of the
  -- sequencer's own count (the chain's: every SEQ.bar_beats from the
  -- patterns' start), the patterns' first beat included (first true
  -- there), after a chain link due on that bar has loaded and before the
  -- bar's first step plays; the functions run in the order registered.
  -- bars is how many bars of the count passed since the last call: 1, but
  -- after a late wake that skipped bars (the call is made once for them
  -- all, at the latest), counted from the bar of a chain link made then
  -- (#1051: the link cleared what came before). Never while the patterns
  -- are stopped
  function M.on_bar(fn)
    if type(fn) ~= "function" then error("on_bar: a hook is a function", 2) end
    table.insert(play.bar_hooks, fn)
  end

  -- A voice's step ------------------------------------------------------

  -- The voice's position starts (a pattern start, a restart, a division
  -- reset's bar, a stop): no step taken, pass 1 with no outcome, every
  -- free lane back at 1 (2c), a loop back at its first step (5a)
  local function start_position(voice_idx, state)
    state.last, state.taken, state.heading, state.pass_length = nil, 0, 1, voice_length(voice_idx)
    state.way = nil
    S.lib.conditions.start(voice_idx)
    S.lib.lanes.start(voice_idx)
    S.lib.loop_roll.start(voice_idx)
  end

  -- Ping-pong's move after last (3.7, design §5.5): up to the pass's
  -- length, then down to 1, no end played twice; turning at an end ends
  -- the pass. A longer length, or a shorter one the leg up can still turn
  -- at (the leg stands on it or below it), applies at once; else the leg
  -- ends at its own top, or goes on down to 1, and the new length applies
  -- at the turn, as reverse does (#743). The leg down turns at 1, which
  -- every length holds. A length of 1 stays on 1, each step a pass. way is
  -- the step's own way (a misstep's, #970; the heading otherwise): the
  -- length is the leg's to apply (state.heading's), the turn the step's.
  -- Returns the step and whether the pass ended
  local function ping_pong_step(state, last, length, way)
    if length <= 1 then return 1, true end
    if length > state.pass_length or (state.heading > 0 and last <= length) then state.pass_length = length end
    local turned = (way > 0 and last >= state.pass_length) or (way < 0 and last <= 1)
    if turned then state.heading, state.pass_length = -way, length end
    return util.clamp(last + (turned and state.heading or way), 1, state.pass_length), turned
  end

  -- The voice's step at its tick, and its position moved on by its
  -- direction (3.7, design §5.5). The first step after a start is the
  -- direction's first (forward 1, reverse the length, ping-pong 1, random
  -- a draw). A pass is pass_length steps taken in forward, reverse and
  -- random (a length change applies at once while fewer steps than it have
  -- been taken, at the pass's end otherwise: forward is 3.6's wrap) and
  -- ends at each turn in ping-pong. At a pass's end the pass count moves
  -- (S.lib.conditions.next_pass), forward starts again at 1 and reverse at
  -- the length, and the overrides end when no set step is left. A
  -- direction change (3.9, #874: state.way, the direction of the step
  -- taken last) ends the pass where the new direction wraps: the count
  -- becomes the position (forward) or the steps left to step 1 (reverse),
  -- so it runs out at the wrap; to ping-pong or random it counts on. A
  -- misstep (seq_misstep percent, one draw made only above 0) moves one
  -- step up or down (a second draw), wrapping by the pass's length (#920),
  -- instead of the direction's move: from a step past that length, to the
  -- nearest step inside (#961); in ping-pong, as a ping-pong step that way,
  -- turning and ending the pass at an end (#970). Forward with misstep 0
  -- draws nothing
  local function take_position(voice_idx)
    local state = play.voices[voice_idx]
    local length = voice_length(voice_idx)
    local way, last = direction(voice_idx), state.last
    local step, pass_ended = nil, false
    if last == nil then
      if way == SEQ.random then
        step = math.random(length)
      else
        step = way == SEQ.reverse and length or 1
      end
    else
      if way ~= state.way and way == SEQ.forward then
        state.taken = last
      elseif way ~= state.way and way == SEQ.reverse then
        state.taken = state.pass_length - last + 1
      end
      if way ~= SEQ.ping_pong then
        if length ~= state.pass_length and state.taken < length then state.pass_length = length end
        if state.taken >= state.pass_length then
          pass_ended, state.taken, state.pass_length = true, 0, length
        end
      end
      local chance = misstep(voice_idx)
      local missed = chance > 0 and math.random() * SEQ.max_misstep < chance and (math.random() < 0.5 and -1 or 1)
      if way == SEQ.ping_pong then
        -- a misstep is a ping-pong step its own way (#970): at an end it
        -- turns and ends the pass; elsewhere the heading stays, and a
        -- waiting length is the leg's to apply, never the misstep's
        step, pass_ended = ping_pong_step(state, last, length, missed or state.heading)
        if pass_ended then state.taken, state.pass_length = 0, length end
      elseif missed then
        -- a neighbor of last, in 1..pass_length: past the top wraps to 1,
        -- past the bottom to the top; from above the length (#961) the
        -- nearest step inside, 1 up and the length's last step down
        local neighbor = last + missed
        step = neighbor < 1 and state.pass_length or neighbor > state.pass_length
          and (missed > 0 and 1 or state.pass_length) or neighbor
      elseif way == SEQ.forward then
        step = (pass_ended or last + 1 > state.pass_length) and 1 or last + 1
      elseif way == SEQ.reverse then
        step = (pass_ended or last - 1 < 1) and state.pass_length or last - 1
      else
        step = math.random(length)
      end
    end
    if pass_ended then
      S.lib.conditions.next_pass(voice_idx)
      -- the pass's end: with no set step left inside its length, no step of
      -- the voice will end its overrides, chord or held values (its only
      -- set step was turned off)
      if (overrides[voice_idx] or chords[voice_idx] or held_values[voice_idx]) and not M.has_set_step(voice_idx) then
        end_overrides(voice_idx)
      end
    end
    state.last, state.taken, state.way = step, state.taken + 1, way
    return step
  end

  -- The voice's step at its tick (take_position): a set step with a
  -- condition or a probability under 100 is conditioned (3.7, design
  -- §5.1): its condition is tested first (S.lib.conditions.test), its
  -- probability drawn once only if it holds, and its outcome recorded
  -- (S.lib.conditions.record); a step that plays plays its first hit.
  -- 2c: each lane is read once, at the tick (S.lib.lanes.read: the step's
  -- key while it follows, its own cell while it is free), and the free
  -- lanes move on (advance); the rest of the tick reads what was read
  -- (S.lib.lanes.last_read). 5a: the step played is the loop's when the
  -- voice has one (S.lib.loop_roll.played_step), asked after take_position,
  -- which moves the voice's own position, passes and conditions as before;
  -- it is the step played, lit and read by the following lanes. Returns the
  -- hits still to play and their spacing
  local function begin_voice_step(voice_idx)
    local state = play.voices[voice_idx]
    at_beat(state.beat)
    local step = S.lib.loop_roll.played_step(voice_idx, take_position(voice_idx))
    S.pattern_sounding_steps[voice_idx] = step
    local lanes = S.lib.lanes
    for _, lane in ipairs(lanes.LANES) do lanes.read(voice_idx, lane, step) end
    lanes.advance(voice_idx)
    local level = S.patterns[voice_idx][step]
    local hits, spacing, semitones, pitches = 0, 0, nil, nil
    local attrs = S.pattern_steps[voice_idx][step] or {}
    local prob = lanes.last_read(voice_idx, "chance") or SEQ.max_prob
    local plays = false
    -- 5b: under a roll the voice's own step takes its position and plays
    -- nothing, drawing nothing (as a skipped tick)
    if level > 0 and not S.lib.loop_roll.rolling(voice_idx) then
      plays = (attrs.cond == nil or S.lib.conditions.test(voice_idx, attrs.cond)) and prob > 0
        and (prob >= SEQ.max_prob or math.random() * SEQ.max_prob < prob)
      if attrs.cond ~= nil or prob < SEQ.max_prob then S.lib.conditions.record(voice_idx, plays) end
    end
    if plays then
      -- the step's own length (a swung pair's), which the 20 ms rule reads
      local division, swing = division_beats(voice_idx), swing_beats(voice_idx)
      local step_beats = division + (state.tick % 2 == 0 and swing or -swing)
      local step_seconds = step_beats * S.lib.params_setup.beat_seconds_now()
      hits = math.min(lanes.last_read(voice_idx, "repeats") or 1,
        math.max(1, math.floor(step_seconds / SEQ.min_ratchet_seconds + 1e-9)))
      local pitch_level = values.pitch_level(voice_idx)
      spacing, semitones = step_beats / hits, step_semitones(voice_idx, attrs, pitch_level)
      -- the chord the voices output plays and the pitches every hit carries, from one reckoning
      local inputs = step_inputs(voice_idx, step_locks(attrs), semitones, pitch_level)
      pitches = step_pitches(voice_idx, inputs)
      stepping[voice_idx] = inputs
      local was_active = S.voices[voice_idx].active
      play_outputs(hit_event(voice_idx, step, 1, hits, level, semitones, pitches))
      stepping[voice_idx] = nil
      if S.voices[voice_idx].active and not was_active then play.started = true end
    end
    finish_beat(state.beat)
    return {step = step, level = level, hits = hits, spacing = spacing, beat = state.beat, semitones = semitones,
      pitches = pitches}
  end

  -- A step's later hit (a ratchet); none under a roll (5b)
  local function play_voice_hit(voice_idx, plan, hit)
    if S.lib.loop_roll.rolling(voice_idx) then return end
    play_outputs(hit_event(voice_idx, plan.step, hit, plan.hits, plan.level, plan.semitones, plan.pitches))
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
      start_position(voice_idx, state)
    end
    state.tick, state.beat = k, beat
  end

  -- No bursts (rule 4): at a wake the voice plays at most one step that has
  -- come. While its next tick has come too, the step at its tick is skipped
  -- (its position moves on, nothing plays, and, 2c, its free lanes move
  -- on, reading nothing; 5a, a loop's own step moves on too) and it takes
  -- that tick, so it plays the latest, at the position the count puts it at
  local function skip_due_ticks(voice_idx)
    while true do
      local k, beat = next_voice_tick(voice_idx)
      if not is_due(beat) then return end
      S.lib.loop_roll.played_step(voice_idx, take_position(voice_idx))
      S.lib.lanes.advance(voice_idx)
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
    start_position(voice_idx, state)
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
  -- is ended (end_clock) and the new one gets a state of its own. Nothing
  -- while the patterns are stopped (#924: a voice's clock runs only while
  -- they play, the "pattern clock" invariant)
  function M.restart_voice(voice_idx, beat)
    if not S.pattern_playing then return end
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
      play.voices[voice_idx] = {anchor = 0, tick = 0, beat = 0}
      start_position(voice_idx, play.voices[voice_idx])
    end
    local running = S.pattern_clock
    S.pattern_clock = nil
    if running then end_clock(running, play.transport, all_posted) end
    play.transport = {anchor = 0, tick = 0, beat = 0}
    for voice_idx in pairs(play.last_hits) do play.last_hits[voice_idx] = nil end
  end
  end_clocks()

  -- Pattern edits ---------------------------------------------------------

  function toggle_pattern_step(voice_idx, step)
    -- Bounds checking to prevent array expansion
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    if step < 1 or step > PATTERN_LENGTH then return end

    -- an empty step on at full brightness, a set one off, through the one
    -- writer of a level. 3.9 (design section 2, Move's values): in move a
    -- step turned on is given a random value A where it has none
    local turned_on = S.patterns[voice_idx][step] == 0
    M.set_level(voice_idx, step, turned_on and MAX_STEP_LEVEL or 0)
    if turned_on and M.step_mode(voice_idx) == "move" and M.step_attr(voice_idx, step, "va") == nil then
      M.set_step_attr(voice_idx, step, "va", math.random(1, MAX_STEP_LEVEL))
    end
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
  -- it forgets the voice's fill (S.seq_euclid, #923: euclid sets its own
  -- after) and redraws nothing (callers do). 3.9: the gate rule is sent
  -- when its answer moved
  function M.replace_pattern(voice_idx, steps)
    if type(voice_idx) ~= "number" or voice_idx % 1 ~= 0 then return end
    if voice_idx < 1 or voice_idx > NUM_VOICES or type(steps) ~= "table" then return end
    local answer = M.gate_wanted(voice_idx)
    for step = 1, PATTERN_LENGTH do
      S.patterns[voice_idx][step] = whole_step_level(steps[step])
    end
    S.seq_euclid[voice_idx] = nil
    end_overrides(voice_idx)
    S.lib.grid_core.end_step_gestures(voice_idx)
    S.lib.mutation.note_pattern_edit(voice_idx)
    if M.gate_wanted(voice_idx) ~= answer then M.send_gate_rule(voice_idx) end
  end

  -- 3.9 grid sequencer (package 4a, design section 3): the whole pattern,
  -- the levels, the steps' settings and the lane lengths. whole(voice): a
  -- deep copy of the playing one, {levels = {16 levels}, steps = {[step] =
  -- settings}, lanes = {[lane] = length}}; nil for no voice
  function M.whole(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    local levels = {}
    for step = 1, PATTERN_LENGTH do levels[step] = S.patterns[voice_idx][step] end
    return {levels = levels, steps = copy_steps({[voice_idx] = S.pattern_steps[voice_idx]})[voice_idx],
      lanes = S.lib.lanes.lengths(voice_idx)}
  end

  -- The door every whole-pattern load goes through (a letter's switch, a
  -- paste, the chain start's undo): the levels through replace_pattern, so
  -- its endings run once (the held values and locks, the held step
  -- gestures, the step editor but for its own replacement, the fill, the
  -- undo), then a copy of the steps' settings and the lane lengths
  -- (S.lib.lanes.set_lengths: a lane it does not name follows), then the
  -- gate rule. pattern is as whole gives it (steps and lanes may be
  -- absent: none); a voice out of range or a pattern with no levels table
  -- does nothing. Redraws are the caller's
  function M.replace_whole(voice_idx, pattern)
    if not valid_voice(voice_idx) or type(pattern) ~= "table" or type(pattern.levels) ~= "table" then return end
    M.replace_pattern(voice_idx, pattern.levels)
    S.pattern_steps[voice_idx] = copy_steps({[voice_idx] = pattern.steps or {}})[voice_idx]
    S.lib.lanes.set_lengths(voice_idx, type(pattern.lanes) == "table" and pattern.lanes or {})
    M.send_gate_rule(voice_idx)
  end

  function clear_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    M.replace_pattern(voice_idx, {})
  end

  -- The voice's levels now, to tell after a whole-pattern change which
  -- steps it turned on
  local function levels_of(voice_idx)
    local levels = {}
    for step = 1, PATTERN_LENGTH do levels[step] = S.patterns[voice_idx][step] end
    return levels
  end

  -- The final review's M2: in move, each step a randomize or a Euclidean
  -- fill turned on (off in `before`, on now) is given a random value A
  -- where it has none, as a tap and the hand's choice of move do
  local function give_move_values(voice_idx, before)
    if M.step_mode(voice_idx) ~= "move" then return end
    for step = 1, PATTERN_LENGTH do
      if before[step] == 0 and S.patterns[voice_idx][step] > 0 and M.step_attr(voice_idx, step, "va") == nil then
        M.set_step_attr(voice_idx, step, "va", math.random(1, MAX_STEP_LEVEL))
      end
    end
  end

  function randomize_pattern(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local before, steps = levels_of(voice_idx), {}
    for step = 1, PATTERN_LENGTH do
      if math.random() > 0.5 then
        steps[step] = math.random(RANDOM_STEP_FLOOR, MAX_STEP_LEVEL)
      else
        steps[step] = 0
      end
    end
    M.replace_pattern(voice_idx, steps)
    give_move_values(voice_idx, before)
  end

  -- Euclidean fill (design 8.5): the voice's first length steps from
  -- er.gen(hits, length, rotation), hits at MAX_STEP_LEVEL and the rest 0;
  -- the steps past the length and every attribute are kept (in move a step
  -- it turns on is given a value A, give_move_values). Any whole hits
  -- and rotation: the hits clamped to 0..length, the rotation wrapped into
  -- 0..length - 1 (design 8.6), and that pair is S.seq_euclid's
  function M.euclid(voice_idx, hits, rotation)
    if not valid_voice(voice_idx) then return end
    -- whole and finite (2^53: the largest whole a float holds exactly)
    if not whole_between(hits, -2 ^ 53, 2 ^ 53) or not whole_between(rotation, -2 ^ 53, 2 ^ 53) then return end
    local length = voice_length(voice_idx)
    hits, rotation = util.clamp(hits, 0, length), rotation % length
    local fill, steps, before = er.gen(hits, length, rotation), {}, levels_of(voice_idx)
    for step = 1, PATTERN_LENGTH do
      steps[step] = step <= length and (fill[step] and MAX_STEP_LEVEL or 0) or S.patterns[voice_idx][step]
    end
    M.replace_pattern(voice_idx, steps)
    give_move_values(voice_idx, before)
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

  -- The patterns' play state (#876), read from the two facts that hold it:
  -- "playing" while they play, "armed" while a start the play key left
  -- waits for the quantizer, "stopped" otherwise. SEQ's hint and the
  -- grid's play key read it; it stores nothing
  function M.play_state()
    if S.pattern_playing then return "playing" end
    return S.lib.quantize.waiting("patterns") and "armed" or "stopped"
  end

  -- #921: the three states SEQ's status line shows, read from the fields
  -- that hold them (nothing stored). Whether a division reset waits for its
  -- bar (play.reset_beat: set by seq_division_reset while the patterns
  -- play, cleared by its bar, a start and a stop)
  function M.reset_armed() return play.reset_beat ~= nil end

  -- The chain's place: the scene it linked last (nil before its first link,
  -- or with no playable scene in its range) and the whole bars to its next
  -- link (the bar in progress counts: 1 just before it), the sequencer's
  -- count being the clock's beats plus play.offset. nil, nil while the chain
  -- is off or the patterns stop (chain.next_beat is nil then)
  function M.chain_place()
    if not (S.pattern_playing and chain.next_beat) then return nil, nil end
    local beats_left = chain.next_beat - (clock.get_beats() + play.offset)
    return chain.current, math.max(1, math.ceil(beats_left / SEQ.bar_beats - SEQ.flt_epsilon))
  end

  -- The step outputs skipped since the last start (play.failed: each failed
  -- once, printed to maiden), their names sorted
  function M.failed_outputs()
    local names = {}
    for name in pairs(play.failed) do names[#names + 1] = name end
    table.sort(names)
    return names
  end

  -- Start (or start again) the patterns now: every voice and the transport
  -- at step 1 on this beat, a running chain at its first scene (the
  -- patterns it replaces held by the undo on SEQ, #922), and every
  -- output that failed is played again. A start the play key left waiting
  -- is dropped (a followed transport start, #625; the waiting start's own
  -- run has left the quantizer already). The clocks that ran end through
  -- end_clocks(all_posted): true for a followed transport start. 3.9: the
  -- gate rule goes to every voice whose answer the start moved (a pulse
  -- voice with a step), before the first hit
  local function start_patterns(all_posted)
    S.lib.quantize.cancel("patterns")
    -- 5b (the controller's ruling on round 1): a start ends every roll, as
    -- a stop does, so the voices play their own steps from it
    for voice_idx = 1, NUM_VOICES do S.lib.loop_roll.end_roll(voice_idx) end
    end_clocks(all_posted)
    -- the sequencer's count is the clock's again (ruling 47)
    play.failed, play.started, play.reset_beat, play.offset = {}, false, nil, 0
    play.generation = play.generation + 1
    local answers = modes.answers()
    S.pattern_playing = true
    modes.send_moved(answers)
    S.pattern_position = 1
    S.pattern_sounding_step = nil
    local beat = clock.get_beats()
    -- every participant is due on this beat, so the last of them repaints
    for voice_idx = 1, NUM_VOICES do play.voices[voice_idx].due = beat end
    play.transport.due = beat
    chain.current, chain.next_beat = nil, nil
    -- the steps before the clocks run fail as a clock's step does (4b's
    -- review round 1): an error stops the patterns (guarded) and is raised
    -- again, never leaving them marked playing with no clock
    guarded(function() end, function()
      if params:get("seq_chain") == 1 then
        S.lib.mutation.hold_patterns({page = S.constants.UI_PAGES.index.SEQ, section = "pattern"}, chain_link)
        chain.next_beat = beat + params:get("seq_chain_bars") * SEQ.bar_beats
      end
      -- 4b (ruling 4b-2): the start's own bar, after its chain link and
      -- before the voices' clocks play their first steps
      play.next_bar = beat + SEQ.bar_beats
      play.run_bar_hooks(true, 1)
    end)
    for voice_idx = 1, NUM_VOICES do M.restart_voice(voice_idx, beat) end
    S.pattern_clock = clock.run(transport_clock, beat)
  end

  function pattern_clock_start() start_patterns(false) end

  -- Stop the patterns: a start the play key left waiting dropped (#625),
  -- every clock ended (end_clocks), the playheads cleared, every override
  -- ended and (when they played) every output's stop run; 3.9: then the
  -- gate rule to every voice whose answer the stop moved (opening every
  -- pulse voice)
  function pattern_clock_stop()
    S.lib.quantize.cancel("patterns")
    local was_playing = S.pattern_playing
    local answers = modes.answers()
    S.pattern_playing = false
    S.pattern_sounding_step = nil
    end_clocks(false)
    -- 5b (ruling 5b-1): a stop ends every roll, cleanup's too (a start does as well)
    for voice_idx = 1, NUM_VOICES do S.lib.loop_roll.end_roll(voice_idx) end
    play.reset_beat, chain.next_beat, play.next_bar = nil, nil, nil
    S.lib.pattern_letters.end_waits()  -- 4b: a stop clears every waiting letter
    end_all_overrides()
    if was_playing then stop_outputs() end
    modes.send_moved(answers)
    grid_redraw()
    -- the header's play mark, SEQ's status line and SETUP's count offset,
    -- whoever stopped them (#921)
    request_redraw()
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
    -- 3.7 (design §5.4): the chain's next scene by three chances
    for _, move in ipairs({"next", "previous", "random"}) do
      params:add{type = "number", id = "seq_chain_" .. move, name = "chain " .. move, min = 0, max = SEQ.max_chance,
        default = SEQ.chain_chances[move], formatter = percent}
    end
    S.lib.quantize.add_params()
    params:add{type = "trigger", id = "seq_division_reset", name = "division reset", action = function()
      if S.pattern_playing then play.reset_beat = next_bar_beat() end
    end}
    params:add{type = "binary", id = "seq_follow_transport", name = "follow transport", behavior = "toggle",
      default = 1}
    -- 3.7 (design §5.2, rulings 10 and 11): fill's latch, never saved on
    params:add{type = "binary", id = "seq_fill", name = "fill", behavior = "toggle", default = 0,
      action = function()
        grid_redraw()
        request_redraw()
      end}
    params:set_save("seq_fill", false)
  end

  -- The per-voice seq params (design 8.1, 8.12, 8.13): a registered record
  -- with discrete scene keys (length, division, gate, swing, direction,
  -- misstep, 3.9's two move targets) and three that crossfade (the gate's
  -- length, release and floor), no VOICE rows
  local record
  record = {
    name = "seq",
    count = 11,
    add = function(voice_idx)
      local add = S.lib.params_setup.add_voice_param
      add(voice_idx, record, "seq_length", {type = "number", name = "seq length", min = 1, max = PATTERN_LENGTH,
        default = PATTERN_LENGTH, action = function(length)
          -- the step that set the voice's overrides is past the new length:
          -- no step of it will end them; 3.9: a held value ends only past
          -- the step that set it (first, so a param is sent once), and one
          -- a lock of that step held comes back
          values.end_held(voice_idx, function(entry) return entry.step <= length end)
          if (last_played[voice_idx] or 0) > length then end_overrides(voice_idx, true) end
          -- 3.9 (5a): a loop past the new length ends, one across it is cut
          S.lib.loop_roll.fit_length(voice_idx, length)
          -- 3.9: a pulse voice's rule counts the steps inside its length
          if M.step_mode(voice_idx) == "pulse" then M.send_gate_rule(voice_idx) end
          grid_redraw()
        end})
      add(voice_idx, record, "seq_division", {type = "option", name = "seq division", options = SEQ.division_names,
        default = SEQ.default_division})
      -- 3.9: the step mode; its own send (add_voice_param's) is the gate
      -- rule's (send_gate_rule), so its action adds the gate length only
      add(voice_idx, record, "seq_gate", {type = "option", name = "seq gate", options = SEQ.modes,
        default = SEQ.default_mode, action = function()
          resend_gate(voice_idx)
          -- 3.9 (design section 2): a mode change ends the voice's held values
          M.end_held_values(voice_idx)
        end})
      add(voice_idx, record, "seq_gate_length", {type = "control", name = "seq gate length",
        controlspec = controlspec.new(SEQ.gate_steps[1], SEQ.gate_steps[2], "exp", 0, SEQ.gate_length_default, "st"),
        action = function() resend_gate(voice_idx) end})
      add(voice_idx, record, "seq_gate_release", {type = "control", name = "seq gate release",
        controlspec = controlspec.new(SEQ.gate_release[1], SEQ.gate_release[2], "exp", 0, SEQ.gate_release_default,
          "s")})
      -- 3.9 grid sequencer (design section 1, The floor): shown in percent
      add(voice_idx, record, "seq_gate_floor", {type = "control", name = "seq gate floor",
        controlspec = controlspec.new(SEQ.gate_floor[1], SEQ.gate_floor[2], "lin", SEQ.gate_floor.step,
          SEQ.gate_floor.default),
        formatter = function(param) return string.format("%d %%", math.floor(param:get() * 100 + 0.5)) end})
      add(voice_idx, record, "seq_swing", {type = "number", name = "seq swing", min = SEQ.swing[1], max = SEQ.swing[2],
        default = SEQ.swing[1]})
      -- 3.7 (design §5.5)
      add(voice_idx, record, "seq_direction", {type = "option", name = "seq direction", options = SEQ.directions,
        default = SEQ.forward})
      add(voice_idx, record, "seq_misstep", {type = "number", name = "seq misstep", min = 0, max = SEQ.max_misstep,
        default = 0, formatter = percent})
      -- 3.9 grid sequencer (design section 2, The values): the two move
      -- targets (S.lib.lanes); a change ends the voice's held values. The
      -- hand's choice (S.lib.lanes.choose_target) adds the filter's opening
      for _, lane in ipairs({"a", "b"}) do
        add(voice_idx, record, S.lib.lanes.MOVE.param[lane], {type = "option", name = "seq move " .. lane:upper(),
          options = S.lib.lanes.options(lane), default = 1, action = function() M.end_held_values(voice_idx) end})
      end
    end,
    -- seq_gate's seqGate is the gate rule for the mode option sent
    grain_keys = {seq_gate = {name = "seqGate", value = function(option, voice_idx) return modes.rule(option, voice_idx) end},
      seq_gate_release = "gateRelease", seq_gate_floor = "gateFloor"},
    -- the voice sync and a start (before voiceOn: grain params only): a
    -- gated voice's gate length, when it changed
    sync = function(voice_idx)
      if gated(voice_idx) then send_gate_seconds(voice_idx, M.gate_seconds(voice_idx)) end
    end,
    scene_defaults = {seq_length = PATTERN_LENGTH, seq_division = SEQ.default_division, seq_gate = SEQ.default_mode,
      seq_gate_length = SEQ.gate_length_default, seq_gate_release = SEQ.gate_release_default, seq_swing = SEQ.swing[1],
      seq_direction = SEQ.forward, seq_misstep = 0, seq_gate_floor = SEQ.gate_floor.default, seq_move_a = 1,
      seq_move_b = 1},
    discrete = {seq_length = {1, PATTERN_LENGTH}, seq_division = {1, #SEQ.division_names},
      seq_gate = {1, #SEQ.modes}, seq_swing = {SEQ.swing[1], SEQ.swing[2]},
      seq_direction = {1, #SEQ.directions}, seq_misstep = {0, SEQ.max_misstep},
      seq_move_a = {1, #S.lib.lanes.TARGETS + 1}, seq_move_b = {1, #S.lib.lanes.TARGETS + 1}},
    scene_ranges = {seq_gate_length = {SEQ.gate_steps[1], SEQ.gate_steps[2]},
      seq_gate_release = {SEQ.gate_release[1], SEQ.gate_release[2]},
      seq_gate_floor = {SEQ.gate_floor[1], SEQ.gate_floor[2]}},
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
  -- installed: from the start step until cleanup (#924: a handler installed
  -- later may still chain to the script's after it; they then move nothing)
  local transport = {previous_start = nil, previous_stop = nil, internal_source = 1, installed = false}

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
    if not transport.installed then
      -- after cleanup: only the handler found at install
    elseif M.follows_transport() then
      start_patterns(true)
      request_redraw()
    else
      play.keep_count()
    end
    if transport.previous_start then transport.previous_start() end
  end

  function transport.stop()
    if transport.installed and M.follows_transport() then
      pattern_clock_stop()
      request_redraw()
    end
    if transport.previous_stop then transport.previous_stop() end
  end

  -- Installing them again (init run twice) changes nothing: the script's
  -- handlers never chain to themselves
  S.register_start(S.constants.START_ORDER.pattern_transport, function()
    transport.installed = true
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
    transport.installed = false
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

  -- 3.9 (#919): what a step holds on its voice ends together. Stopped, no
  -- voice holds a step's overrides, step, chord, region, slice, begun
  -- inputs or (3.9 grid sequencer, 2a) held values; a region's end flag goes with its region, and a step slice is
  -- the last played step's. gate_sent outlives a stop (the engine keeps
  -- gateSeconds, #639): it holds only voices and gate lengths gate_seconds gives
  local held_tables = {{"overrides", overrides}, {"last_played", last_played}, {"chords", chords},
    {"step_regions", step_regions}, {"step_slices", step_slices}, {"step_region_to_end", step_region_to_end},
    {"stepping", stepping}, {"held_values", held_values}}
  S.register_invariant("step holds", function()
    if not S.pattern_playing then
      for _, entry in ipairs(held_tables) do
        local voice_idx = next(entry[2])
        if voice_idx ~= nil then
          return "stopped, but " .. entry[1] .. "[" .. tostring(voice_idx) .. "] is " .. tostring(entry[2][voice_idx])
        end
      end
    end
    for voice_idx = 1, NUM_VOICES do
      if step_region_to_end[voice_idx] ~= nil and step_regions[voice_idx] == nil then
        return "step_region_to_end[" .. voice_idx .. "] is " .. tostring(step_region_to_end[voice_idx]) .. " with no region"
      end
      -- 3.9 grid sequencer (2a): a held value's param has a base override
      -- (its own, or a lock's over it), so a record never outlives its value
      for target, entry in pairs(held_values[voice_idx] or {}) do
        if not S.lib.engine_sync.is_overridden(entry.param) then
          return "held_values[" .. voice_idx .. "]." .. tostring(target) .. " is on " .. tostring(entry.param)
            .. ", which no override holds"
        end
      end
      local slice = step_slices[voice_idx]
      if slice and slice.step ~= last_played[voice_idx] then
        return "step_slices[" .. voice_idx .. "] is step " .. tostring(slice.step) .. "'s, but the last played is "
          .. tostring(last_played[voice_idx])
      end
    end
    for voice_idx, seconds in pairs(gate_sent) do
      if not valid_voice(voice_idx) or type(seconds) ~= "number" or seconds < SEQ.gate_seconds[1]
          or seconds > SEQ.gate_seconds[2] then
        return "gate_sent[" .. tostring(voice_idx) .. "] is " .. tostring(seconds) .. ", no voice's gate length"
      end
    end
  end)

  -- 3.9 grid sequencer (design section 7, ruling 1b-2): for a running
  -- voice, the mode the engine sync last sent for v<i>_seq_gate (its
  -- expected value; after a start, which records none, the stored one the
  -- start sent) gives the grain key the rule's answer now. What the engine
  -- was sent is the stub's to check (the step gate table): this is what Lua
  -- can see, and it fails on a mode change that was never sent
  S.register_invariant("step gate", function()
    for voice_idx = 1, NUM_VOICES do
      if S.voices[voice_idx].active then
        local sent = S.lib.engine_sync.expected_value(voice_param(voice_idx, "seq_gate"))
        if sent == nil then sent = voice_values(voice_idx).seq_gate end
        if modes.rule(sent, voice_idx) ~= M.gate_wanted(voice_idx) then
          return "voice " .. voice_idx .. " was sent mode " .. tostring(sent) .. ", whose seqGate is "
            .. modes.rule(sent, voice_idx) .. ", not the rule's " .. M.gate_wanted(voice_idx)
        end
      end
    end
  end)

  return M
end

-- lib/notes.lua
-- Notes (3.5, design §2, §6.4): a voice's NOTE_SLOTS slots, slot 1 its own
-- note and the rest extra notes from a pool every voice shares. The one
-- module that allocates slots, steals, and sends noteOn, noteOff,
-- noteExpression and setNotePool. play's six branches, release and the
-- own note's park, the pool setting (data/strata/notes.data, read at the
-- start step notes_load, written by set_pool, through S.lib.data_files),
-- note_values and the freeze reference, the expression flush (an LFO step
-- hook, at most NOTES.sends_per_step a step), the per-voice note cap
-- (v<i>_note_cap, a registered voice param, PSET only), the voice-stop and
-- freeze-change hooks, the cleanup step notes and the invariant "notes".
-- 3.7 (design §3.4, §3.5): a note's region (the own note's, sent as the
-- regionStart and regionLength grain params; an extra slot's, noteRegion),
-- a note that plays to its end (to_end, hold_to_end), own_only, the grid's
-- owner and a steal of the caller's own kind (steals). See
-- docs/notes/lua/notes.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NOTE_SLOTS = S.constants.NOTE_SLOTS
  local NOTE_POOL = S.constants.NOTE_POOL
  local musicutil = require "musicutil"

  -- The module's tunables: notes.data's name and format version, a stolen
  -- note's cut (the engine's fade, seconds: no note younger than it is
  -- stolen), the most noteExpression messages one 48 Hz step sends, the
  -- note that plays at rate 1, the engine's rate and note ranges, A4 (a
  -- frequency's note), the owners, a note's expression (its keys in
  -- noteExpression's order, the neutral values, the engine's ranges) and
  -- the note cap's param and VOICE section
  local NOTES = {file = "notes.data", version = 1, backup_suffix = ".bak", cut_seconds = 0.05, sends_per_step = 16,
    rate_root_note = 60, rate_range = {0.25, 4}, note_range = {0, 127}, a4 = {note = 69, freq = 440},
    owners = {midi = true, seq = true, grid = true},  -- 3.7: a grid's slice keys (key port * 100 + slice)
    step_owner = "seq",  -- the sequencer's owner (SEQ.note_owner): its chord's extra notes are no hit of their own
    expression_keys = {"bend", "amp", "position", "size", "main"},
    neutral = {bend = 1, amp = 1, position = 0, size = 0, main = 0},
    expression_ranges = {bend = {0.0625, 16}, amp = {0, 2}, position = {-1, 1}, size = {-1, 1}, main = {-1, 1}},
    cap = {key = "note_cap", name = "note cap", section = "notes", before = "variation"},
    -- each voice's {attack, release} (s): its def's times, which the engine
    -- plays when no param says otherwise (a docs test compares them), and
    -- the engine's ranges (voiceEnvelope clips to them)
    envelope = {{4, 8}, {5, 10}, {3, 6}, {8, 12}, {2, 4}, {0.01, 2}, {3, 5}},
    envelope_ranges = {attack = {0.005, 30}, release = {0.01, 30}},
    envelope_keys = {"attack", "release"}, envelope_engine = {attack = "attackTime", release = "releaseTime"}}
  M.NOTES = NOTES

  -- The pool notes.data holds (nil: none read or set, the tier's default)
  local pool_setting = nil

  -- Per voice: slots[v][s] the note in slot s (nil: free); ended[v][s] when
  -- the slot's last note ended (nil: never used); sent[v][s] the expression
  -- the engine keeps for the slot; references[v] a frozen synth voice's
  -- freeze reference; lowered[v] while its cap was lowered under a used slot
  local slots, ended, sent, references, lowered = {}, {}, {}, {}, {}
  -- 3.7: own_regions[v] the own note's region ({start, length}, nil: the
  -- loop's); regions_sent[v][s] the region the engine keeps for extra slot s
  -- ({0, 0} until a noteRegion, and again after the voice's stop)
  local own_regions, regions_sent = {}, {}
  local NO_REGION = {0, 0}
  -- The flush: the notes due, in the order first marked
  local flush = {queue = {}, stopped = false, hooked = false}

  local function whole_in(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
  end

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function copy_expression(expression)
    local copy = {}
    for _, key in ipairs(NOTES.expression_keys) do copy[key] = expression[key] end
    return copy
  end

  local function copy_region(region) return region and {region[1], region[2]} end
  local function same_region(a, b)
    a, b = a or NO_REGION, b or NO_REGION
    return a[1] == b[1] and a[2] == b[2]
  end

  for voice = 1, NUM_VOICES do
    slots[voice], ended[voice], sent[voice], regions_sent[voice] = {}, {}, {}, {}
    for slot = 1, NOTE_SLOTS do sent[voice][slot] = copy_expression(NOTES.neutral) end
    -- the engine's alloc: every slot's region 0, 0
    for slot = 2, NOTE_SLOTS do regions_sent[voice][slot] = copy_region(NO_REGION) end
  end

  local function notes_path() return _path.data .. "strata/" .. NOTES.file end

  -- The running tier's default pool (standard's while the tier is unknown)
  local function tier_default()
    return NOTE_POOL[S.performance and S.performance.tier] or NOTE_POOL.standard
  end

  -- base with each finite number of values (a table, or nil) clipped to its
  -- range in its place; what values lacks is base's
  local function merged_expression(base, values)
    local merged = copy_expression(base)
    if type(values) == "table" then
      for _, key in ipairs(NOTES.expression_keys) do
        if finite(values[key]) then
          local range = NOTES.expression_ranges[key]
          merged[key] = util.clamp(values[key], range[1], range[2])
        end
      end
    end
    return merged
  end

  local function same_expression(a, b)
    for _, key in ipairs(NOTES.expression_keys) do
      if a[key] ~= b[key] then return false end
    end
    return true
  end

  local function note_cap(voice)
    local values = S.voices[voice].values
    local cap = values and values[NOTES.cap.key]
    if whole_in(cap, 1, NOTE_SLOTS) then return cap end
    return NOTE_SLOTS
  end

  local function frozen_synth(voice)
    return voice_uses_synth(voice) and S.lib.freeze.is_frozen(voice)
  end

  -- What a voice's freq plays now (a step's note override included), as a
  -- fractional MIDI note
  local function freq_note(voice)
    local freq = S.lib.engine_sync.engine_base_value("v" .. voice .. "_freq")
    return NOTES.a4.note + 12 * math.log(freq / NOTES.a4.freq) / math.log(2)
  end

  -- Messages: each counted in the engine budget's window, never deferred
  local function count(n) if n > 0 then S.lib.engine_sync.count_sends(n) end end

  local function send_expression(voice, slot, expression)
    engine.noteExpression(voice - 1, slot - 1, expression.bend, expression.amp, expression.position,
      expression.size, expression.main)
    sent[voice][slot] = copy_expression(expression)
  end

  local function send_note_on(voice, slot, record)
    local values = M.note_values(voice, record.pitch)
    engine.noteOn(voice - 1, slot - 1, values.note, values.freq, values.rate, record.velocity)
  end

  -- 3.7: an extra slot's region before its noteOn, when the note has one or
  -- the slot's last was not 0, 0 (then 0, 0): the number of messages sent
  local function send_slot_region(voice, slot, region)
    if same_region(region, regions_sent[voice][slot]) then return 0 end
    local wanted = region or NO_REGION
    engine.noteRegion(voice - 1, slot - 1, wanted[1], wanted[2])
    regions_sent[voice][slot] = copy_region(wanted)
    return 1
  end

  -- The seconds a one-shot buffer voice takes to pass fraction of its
  -- slot's valid region (S.lib.scan), or nil (no one shot, or a scan of
  -- 0); lib/slices.lua reads it through M.pass_seconds
  local function pass_seconds(voice, fraction)
    local seconds = S.lib.scan.pass_seconds(voice, fraction)
    if finite(seconds) and seconds > 0 then return seconds end
    return nil
  end
  M.pass_seconds = pass_seconds

  -- When an extra note ends by itself (util.time()), or nil: the note's own
  -- to_end, else on a one-shot buffer voice its pass over its region or
  -- over the voice's loop
  local function ends_at(voice, played, now)
    local seconds = played.to_end
    if seconds == nil and voice_uses_buffer(voice) then
      seconds = pass_seconds(voice, played.region and played.region[2] or params:get("v" .. voice .. "_loop_length"))
    end
    return seconds and now + seconds or nil
  end

  -- The count MAIN shows changed
  local function held_changed()
    update_voice_list()
    request_redraw()
  end

  local function update_lowered(voice)
    local cap = note_cap(voice)
    lowered[voice] = nil
    for slot = cap + 1, NOTE_SLOTS do
      if slots[voice][slot] then lowered[voice] = true end
    end
  end

  local function new_record(voice, slot, played, now)
    return {voice = voice, slot = slot, owner = played.owner, key = played.key, pitch = played.pitch,
      velocity = played.velocity, park = played.park, quiet = played.quiet, held = true, parked = false, started = now,
      expression = copy_expression(played.expression), due = false, region = copy_region(played.region),
      hold_to_end = played.hold_to_end}
  end

  -- 3.6's note hooks (S.registry.note_hooks, read at each call): each
  -- hook's field function, contained, with (voice, slot, note = a fresh
  -- {owner, key, pitch, velocity}). started once a record is in its slot,
  -- moved for a held note re-pitched in place, ended when a held note
  -- leaves its slot or parks (a parked note already ended), expressed when
  -- a note becomes due for the flush: one ended per started
  local hook_errors = {}
  local function run_note_hooks(field, record)
    for _, hook in ipairs(S.registry.note_hooks) do
      if hook[field] then
        S.lib.ui_frame.contained_call(hook_errors, hook.name .. " " .. field, "note hook " .. hook.name .. " " .. field,
          hook[field], record.voice, record.slot,
          {owner = record.owner, key = record.key, pitch = record.pitch, velocity = record.velocity})
      end
    end
  end

  -- A note leaves its slot: the flush skips it, and a held one's slot ended
  -- now (and the hooks hear it ended, unless moved: its next record carries on)
  local function forget(record, now, moved)
    slots[record.voice][record.slot] = nil
    record.due = false
    local was_held = record.held
    if was_held then ended[record.voice][record.slot] = now end
    record.held = false
    if was_held and not moved then run_note_hooks("ended", record) end
  end

  local function mark_due(record)
    if flush.stopped or record.due then return end
    record.due = true
    table.insert(flush.queue, record)
    run_note_hooks("expressed", record)
  end

  -- The oldest held extra note that accepts(record) and started at least
  -- the cut time ago (a tie: the first by voice, then slot)
  local function oldest(accepts, now)
    local found
    for voice = 1, NUM_VOICES do
      for slot = 2, NOTE_SLOTS do
        local record = slots[voice][slot]
        if record and now - record.started >= NOTES.cut_seconds and accepts(record)
            and (found == nil or record.started < found.started) then
          found = record
        end
      end
    end
    return found
  end

  -- The free extra slot under the cap whose last note ended longest ago (a
  -- never used one first; a tie: the lowest)
  local function free_slot(voice, cap)
    local found, found_end
    for slot = 2, cap do
      if slots[voice][slot] == nil then
        local slot_end = ended[voice][slot] or -math.huge
        if found == nil or slot_end < found_end then found, found_end = slot, slot_end end
      end
    end
    return found
  end

  local function others_held(voice)
    for slot = 2, NOTE_SLOTS do
      if slots[voice][slot] then return true end
    end
    return false
  end

  function M.held(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return 0 end
    local held = 0
    for slot = 1, NOTE_SLOTS do
      if slots[voice][slot] and slots[voice][slot].held then held = held + 1 end
    end
    return held
  end

  function M.pool_used()
    local used = 0
    for voice = 1, NUM_VOICES do
      for slot = 2, NOTE_SLOTS do
        if slots[voice][slot] then used = used + 1 end
      end
    end
    return used
  end

  -- The slot of voice's held note of owner and key (nil: none)
  function M.find(voice, owner, key)
    if not whole_in(voice, 1, NUM_VOICES) then return nil end
    for slot = 1, NOTE_SLOTS do
      local record = slots[voice][slot]
      if record and record.held and record.owner == owner and record.key == key then return slot end
    end
    return nil
  end

  -- voice's used slots, in order: copies of {slot, owner, key, pitch, held, parked}
  function M.slots(voice)
    local list = {}
    if not whole_in(voice, 1, NUM_VOICES) then return list end
    for slot = 1, NOTE_SLOTS do
      local record = slots[voice][slot]
      if record then
        table.insert(list, {slot = slot, owner = record.owner, key = record.key, pitch = record.pitch,
          held = record.held, parked = record.parked, region = copy_region(record.region),
          hold_to_end = record.hold_to_end})
      end
    end
    return list
  end

  -- The extra notes the voices share: notes.data's, else the tier's default
  function M.pool()
    if pool_setting ~= nil then return pool_setting end
    return tier_default()
  end

  -- A frozen synth voice's freeze reference (a fractional MIDI note): the
  -- note its freq played when it froze or, since, when it last started or
  -- changed source (the hooks below keep it; a running voice found without
  -- one takes it then). A stopped voice keeps none: asked, it gives its
  -- freq's note now, what its start will take. nil for any other voice
  function M.freeze_reference(voice)
    if not whole_in(voice, 1, NUM_VOICES) or not frozen_synth(voice) then return nil end
    if references[voice] ~= nil then return references[voice] end
    if not S.voices[voice].active then return freq_note(voice) end
    references[voice] = freq_note(voice)
    return references[voice]
  end

  -- A start or a source change: the old reference goes, and a fresh one is
  -- taken when the voice is a frozen synth voice and take is true
  local function refresh_reference(voice, take)
    references[voice] = nil
    if take and frozen_synth(voice) then references[voice] = freq_note(voice) end
  end

  -- What the engine plays for pitch (a MIDI note number, fractional
  -- allowed) on voice: {note = pitch clamped to 0-127, freq = its frequency
  -- clamped to the voice's freq range, rate = 2 ^ ((pitch - root) / 12), the
  -- root S.lib.samples.rate_root (60, or a buffer voice's file's key), or
  -- from the freeze reference on a frozen synth voice, clamped to the
  -- engine's 0.25-4}; nil for a voice outside 1..NUM_VOICES or a pitch that
  -- is not a finite number. Every note's pitch becomes what the engine plays
  -- here; a tuning also reaches the key's pitch, the scale snap, a degree, a
  -- chord's notes and the engine's quantize table
  function M.note_values(voice, pitch)
    if not whole_in(voice, 1, NUM_VOICES) or not finite(pitch) then return nil end
    local min_freq, max_freq = param_range("v" .. voice .. "_freq")
    local root = M.freeze_reference(voice) or S.lib.samples.rate_root(voice)
    return {
      note = util.clamp(pitch, NOTES.note_range[1], NOTES.note_range[2]),
      freq = util.clamp(musicutil.note_num_to_freq(pitch), min_freq, max_freq),
      rate = util.clamp(2 ^ ((pitch - root) / 12), NOTES.rate_range[1], NOTES.rate_range[2]),
    }
  end

  -- The voice's own pitch now, as a fractional MIDI note: a synth voice's
  -- freq, a buffer voice's rate, an input voice's grain pitch (rate 1 at
  -- S.lib.samples.rate_root: a buffer voice's file's key, else 60), each as the engine plays it (a step's override
  -- included)
  local function own_pitch(voice)
    if voice_uses_synth(voice) then return freq_note(voice) end
    local key = voice_uses_buffer(voice) and "buf_rate" or "grain_pitch"
    local rate = S.lib.engine_sync.engine_base_value("v" .. voice .. "_" .. key)
    return S.lib.samples.rate_root(voice) + 12 * math.log(rate) / math.log(2)
  end

  -- The voice's own pitch now, as a fractional MIDI note (a slice note's, 3.7)
  function M.own_pitch(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return nil end
    return own_pitch(voice)
  end

  local function valid_region(region)
    return type(region) == "table" and finite(region[1]) and finite(region[2]) and region[1] >= 0 and region[1] < 1
      and region[2] > 0 and region[2] <= 1
  end

  -- 3.7 (design §3.4): the own note's region, a copy, or nil (the loop's)
  function M.own_region(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return nil end
    return copy_region(own_regions[voice])
  end

  -- Send the own region as it is (setGrainParam regionStart, then
  -- regionLength: 0 and 0 for none): set_own_region's send, and every voice
  -- sync's (the slices record's sync, before voiceOn at a start), so this
  -- module is the own region's one sender (the final review's M-5)
  function M.sync_own_region(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return end
    local wanted = own_regions[voice] or NO_REGION
    engine.setGrainParam(voice - 1, "regionStart", wanted[1])
    engine.setGrainParam(voice - 1, "regionLength", wanted[2])
  end

  -- Set the own note's region ({start, length} fractions of the slot's
  -- valid region, or nil): stored, and while the voice runs sent
  -- (setGrainParam regionStart, then regionLength: 0 and 0 for nil), with
  -- the playhead's restart, since the engine restarts the own scan at every
  -- regionLength. A hit (hit true: a slice played, a step's slice) sends
  -- even the same region, so a re-hit of the same slice restarts its scan,
  -- in wrap and bounce; anything else sends only a change. On a one-shot
  -- voice the retrigger that follows every hit restarts the engine's scan
  -- and the playhead (positionsHit, lib/playheads.lua's voice_hit hook), so
  -- a hit there sends only a change and leaves the playhead to the hook:
  -- one restart a hit in every mode. A stopped voice's start sends it (the
  -- slices record's sync, through M.sync_own_region). false for a bad voice
  -- or region
  function M.set_own_region(voice, region, hit)
    if not whole_in(voice, 1, NUM_VOICES) or (region ~= nil and not valid_region(region)) then return false end
    local one_shot_hit = hit and S.lib.scan.mode(voice) == S.lib.scan.MODE.one_shot
    if (not hit or one_shot_hit) and same_region(own_regions[voice], region) then return true end
    own_regions[voice] = copy_region(region)
    if S.voices[voice].active then
      M.sync_own_region(voice)
      count(2)
      if not one_shot_hit then S.lib.playheads.reset(voice) end
    end
    return true
  end

  -- Ruling 39: a running voice with no held note never keeps its own note
  -- parked. When a release, a steal or a freeze's cuts end a voice's last
  -- held note under its parked own note, the own note returns at once,
  -- neutral (a noteExpression of the neutral values first, when the
  -- engine's for slot 0 is not neutral: the lifted finger's bend or amp
  -- never carries into the drone), at the voice's pitch and with no accent
  -- (velocity 0), and its record goes: the voice sounds on as its drone,
  -- nobody's note
  local function unpark_alone(voice, now)
    local own = slots[voice][1]
    if not (own and own.parked and S.voices[voice].active) or M.held(voice) > 0 then return end
    local messages = 1
    if not same_expression(sent[voice][1], NOTES.neutral) then
      send_expression(voice, 1, NOTES.neutral)
      messages = 2
    end
    local values = M.note_values(voice, own_pitch(voice))
    engine.noteOn(voice - 1, 0, values.note, values.freq, values.rate, 0)
    count(messages)
    forget(own, now)
  end

  -- Slot 1 (branches 1, 2 and 6), one rule for both kinds of play: the
  -- player pitches the own note (set_own); unless quiet, a stopped voice
  -- starts and the note's expression goes when the engine's differs (quiet:
  -- it waits for the flush); noteOn on slot 0, to a running voice only, when
  -- the own note was parked (the unpark, so Lua and the engine agree) or the
  -- voice is a frozen synth voice (it alone carries the rate, ruling 18: a
  -- stopped one gets it from the grain-restart hook at its start); then
  -- retrigger unless quiet (the stage's step gate and accent open only on
  -- it, ruling 15: a quiet play's caller starts and accents). The old record
  -- goes before the start, so the hook never plays it
  local function play_own(voice, note, played, now)
    local previous = slots[voice][1]
    local was_parked = previous ~= nil and previous.parked
    local held_before = M.held(voice)
    -- the same owner and key held: the hooks hear a move, not an end and a start
    local moved = previous ~= nil and previous.held and previous.owner == played.owner and previous.key == played.key
    note.set_own(played.pitch)
    -- 3.7: the note's region before its start or its hit, so the start's
    -- sync carries it and the first grain plays it
    if played.region then M.set_own_region(voice, played.region, true) end
    if previous then forget(previous, now, moved) end
    -- the retrigger below always follows this start: the two are one hit
    if not note.quiet and not S.voices[voice].active then toggle_voice(voice, {retrigger_follows = true}) end
    local record = new_record(voice, 1, played, now)
    -- 3.7: an own note with to_end (a one-shot slice) ends at its time too
    record.ends_at = played.to_end and now + played.to_end or nil
    slots[voice][1] = record
    run_note_hooks(moved and "moved" or "started", record)
    local messages = 0
    if not same_expression(record.expression, sent[voice][1]) then
      if note.quiet then
        mark_due(record)
      else
        send_expression(voice, 1, record.expression)
        messages = 1
      end
    end
    if (was_parked or frozen_synth(voice)) and S.voices[voice].active then
      send_note_on(voice, 1, record)
      messages = messages + 1
    end
    if not note.quiet then S.lib.engine_sync.retrigger(voice, record.velocity, "note") end
    count(messages)
    if M.held(voice) ~= held_before then held_changed() end
    return 1
  end

  -- An extra note starts in slot (free, or stolen in place): its first
  -- expression, then its noteOn; a hit (the voice_hit hooks, 3.7) unless
  -- it is a step's chord's, whose step is the one hit
  local function start_extra(voice, slot, played, now)
    local record = new_record(voice, slot, played, now)
    record.ends_at = ends_at(voice, played, now)
    slots[voice][slot] = record
    run_note_hooks("started", record)
    send_expression(voice, slot, record.expression)
    local messages = 2 + send_slot_region(voice, slot, record.region)
    send_note_on(voice, slot, record)
    count(messages)
    if played.owner ~= NOTES.step_owner then S.lib.engine_sync.extra_note_hit(voice, slot, record.velocity) end
    return slot
  end

  local release_slot  -- below: play's own_only lets the same key's extra note go first

  local function valid_note(note)
    -- a key equals itself (never nil or NaN), or the note could never be found again
    return type(note) == "table" and NOTES.owners[note.owner] == true and note.key ~= nil and note.key == note.key
      and finite(note.pitch)
      and finite(note.velocity) and type(note.set_own) == "function"
      and (note.park == nil or type(note.park) == "boolean") and (note.quiet == nil or type(note.quiet) == "boolean")
      and (note.extra_only == nil or type(note.extra_only) == "boolean")
      and (note.expression == nil or type(note.expression) == "table")
      -- 3.7's (design §3.5)
      and (note.region == nil or valid_region(note.region))
      and (note.to_end == nil or (finite(note.to_end) and note.to_end > 0))
      and (note.hold_to_end == nil or type(note.hold_to_end) == "boolean")
      and (note.own_only == nil or type(note.own_only) == "boolean")
      and (note.steals == nil or type(note.steals) == "function")
  end

  -- Play note = {owner, key, pitch, velocity, set_own, park, quiet,
  -- extra_only, expression} on voice (design §2.2): the slot it took, nil
  -- when refused. extra_only (default false) true: only branch 1 (its own
  -- held slot again) or 3 (a free extra slot with room in the pool); never
  -- slot 1 otherwise, never a steal: refused, sending and recording nothing
  -- (ruling 32: a chord's further notes take only free room). 3.7's
  -- fields: region {start, length} (fractions 0-1 of the slot's valid
  -- region, a length above 0: the own note's through set_own_region, an
  -- extra slot's by noteRegion before its noteOn); to_end seconds (an extra
  -- note ends by itself then, at the flush's step; on a one-shot buffer
  -- voice a note without one takes its pass, S.lib.scan); hold_to_end (its
  -- key's release leaves it: M.release returns false); own_only (always the
  -- own note); steals(owner, key) (an extra_only note that finds no room
  -- cuts the voice's oldest extra note it answers true for and takes its slot)
  function M.play(voice, note)
    if not whole_in(voice, 1, NUM_VOICES) or not valid_note(note) then return nil end
    -- a running frozen synth voice's reference, before set_own can move the
    -- freq (the hooks keep one already; a stopped voice's start takes its own)
    if S.voices[voice].active then M.freeze_reference(voice) end
    local now = util.time()
    local played = {owner = note.owner, key = note.key, pitch = note.pitch, park = note.park == true,
      quiet = note.quiet == true, velocity = util.clamp(note.velocity, 0, 1),
      expression = merged_expression(NOTES.neutral, note.expression),
      region = copy_region(note.region), to_end = note.to_end, hold_to_end = note.hold_to_end == true}
    -- 1. the same owner and key held: that slot again, re-pitched and accented
    local slot = M.find(voice, note.owner, note.key)
    if note.own_only then
      -- 3.7: the own note always (the same key held in an extra slot goes first)
      if slot and slot > 1 then release_slot(voice, slot) end
      return play_own(voice, note, played, now)
    end
    if slot == 1 then return play_own(voice, note, played, now) end
    if slot then
      local record = slots[voice][slot]
      record.pitch, record.velocity, record.park = played.pitch, played.velocity, played.park
      record.expression, record.due = played.expression, false
      record.region, record.hold_to_end, record.ends_at = played.region, played.hold_to_end, ends_at(voice, played, now)
      local messages = 1
      if not same_expression(played.expression, sent[voice][slot]) then
        send_expression(voice, slot, played.expression)
        messages = 2
      end
      messages = messages + send_slot_region(voice, slot, record.region)
      send_note_on(voice, slot, record)
      count(messages)
      run_note_hooks("moved", record)
      -- a hit (3.7), as the engine's accent of the slot is, unless it is a
      -- step's chord replayed at a ratchet: that step's retrigger is its hit
      if played.owner ~= NOTES.step_owner then S.lib.engine_sync.extra_note_hit(voice, slot, record.velocity) end
      return slot
    end
    -- 2. slot 1 free: nothing held, the own note parked, or the voice
    -- stopped (ruling 19: a stopped voice's slot 1 is always free, whatever
    -- quiet note its caller never started), so branches 3 to 6 run only on
    -- a running voice
    local own = slots[voice][1]
    if note.extra_only then
      -- 3 alone: a free extra slot under the cap, room in the pool, a running voice
      local active = S.voices[voice].active
      local free = active and free_slot(voice, note_cap(voice))
      if active and note.steals and (not free or M.pool_used() >= M.pool()) then
        -- 3.7: no room, so the voice's oldest note of the caller's kind is cut and its slot taken
        local victim = oldest(function(record)
          return record.voice == voice and record.slot <= note_cap(voice) and note.steals(record.owner, record.key) == true
        end, now)
        if victim then
          engine.noteOff(voice - 1, victim.slot - 1, 1)
          count(1)
          forget(victim, now)
          free = victim.slot
        end
      end
      if not free or M.pool_used() >= M.pool() then return nil end
      start_extra(voice, free, played, now)
      held_changed()
      return free
    end
    if own == nil or own.parked or not S.voices[voice].active then return play_own(voice, note, played, now) end
    local cap = note_cap(voice)
    local free = free_slot(voice, cap)
    if free then
      -- 3. room in the pool; 4. else the oldest held extra note anywhere is
      -- cut, but a locked voice's for another voice
      if M.pool_used() >= M.pool() then
        local victim = oldest(function(record) return record.voice == voice or not S.locked[record.voice] end, now)
        if victim then
          engine.noteOff(victim.voice - 1, victim.slot - 1, 1)
          count(1)
          forget(victim, now)
          update_lowered(victim.voice)
          unpark_alone(victim.voice, now)  -- ruling 39: the victim's voice may hold nothing now
        else
          free = nil
        end
      end
      if free then
        start_extra(voice, free, played, now)
        held_changed()
        return free
      end
    else
      -- 5. no free slot under the cap: the voice's oldest extra note under it, in place
      local victim = oldest(function(record) return record.voice == voice and record.slot <= cap end, now)
      if victim then
        forget(victim, now)
        return start_extra(voice, victim.slot, played, now)
      end
    end
    -- 6. nothing can be stolen: slot 1, the newest note winning
    return play_own(voice, note, played, now)
  end

  -- End voice's held note of owner and key: noteOff (a release) for an
  -- extra note (and, when it was the voice's last held note, its parked own
  -- note returns, ruling 39); the own note parks (noteOff on slot 0) when it
  -- asked to and another note is held, and otherwise sends nothing. true
  -- when a note ended
  function release_slot(voice, slot)
    local record = slots[voice][slot]
    if slot > 1 then
      local now = util.time()
      engine.noteOff(voice - 1, slot - 1, 0)
      count(1)
      forget(record, now)
      update_lowered(voice)
      unpark_alone(voice, now)
    elseif record.park and others_held(voice) then
      engine.noteOff(voice - 1, 0, 0)
      count(1)
      record.held, record.parked, record.due = false, true, false
      run_note_hooks("ended", record)  -- a parked note that plays again is a new start
    else
      forget(record, util.time())
    end
    held_changed()
  end

  -- A note held to its end (3.7's hold_to_end) is left alone: false
  function M.release(voice, owner, key)
    local slot = M.find(voice, owner, key)
    if not slot or slots[voice][slot].hold_to_end then return false end
    release_slot(voice, slot)
    return true
  end

  -- 3.7: whether a held note of voice plays to its end (hold_to_end)
  function M.plays_to_end(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return false end
    for slot = 1, NOTE_SLOTS do
      local record = slots[voice][slot]
      if record and record.held and record.hold_to_end then return true end
    end
    return false
  end

  -- 3.7: a voice's notes with a region end (a bind of the slot it reads,
  -- lib/slices.lua): each extra note with one is released, and the own
  -- region cleared (sent to a running voice)
  local function end_extra_regions(voice)
    for slot = 2, NOTE_SLOTS do
      local record = slots[voice][slot]
      if record and record.region then release_slot(voice, slot) end
    end
  end
  function M.end_regions(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return end
    end_extra_regions(voice)
    M.set_own_region(voice, nil)
  end

  -- Every held note of owner on voice, the extra ones first, then the own
  -- note (which so parks only under another owner's). A note held to its
  -- end (3.7's hold_to_end, a one-shot slice) is left alone, as M.release
  -- leaves it: latch's next chord, or a step's chord ending, never cuts a
  -- slice still playing to its end (the final review's I-1)
  function M.release_owner(voice, owner)
    if not whole_in(voice, 1, NUM_VOICES) then return end
    local order = {}
    for slot = 2, NOTE_SLOTS do table.insert(order, slot) end
    table.insert(order, 1)
    for _, slot in ipairs(order) do
      local record = slots[voice][slot]
      if record and record.held and record.owner == owner and not record.hold_to_end then release_slot(voice, slot) end
    end
  end

  -- Ruling 40: owner lets go of voice without parking anything. Its held
  -- extra notes are released (noteOff), and its held own note is dropped
  -- from the records with nothing sent: the own note keeps sounding and is
  -- simply no longer the owner's. An own note it parked earlier stays
  -- parked under the other owners' notes and returns when the voice's last
  -- note ends (ruling 39)
  function M.forget_owner(voice, owner)
    if not whole_in(voice, 1, NUM_VOICES) then return end
    for slot = 2, NOTE_SLOTS do
      local record = slots[voice][slot]
      if record and record.held and record.owner == owner then release_slot(voice, slot) end
    end
    local own = slots[voice][1]
    if own and own.held and own.owner == owner then
      forget(own, util.time())
      held_changed()
    end
  end

  -- Ruling 55: forget_owner's way for one held note of owner and key: an
  -- extra note is released (noteOff), the own note dropped from the records
  -- with nothing sent (it sounds on as nobody's). true when a note went
  function M.forget(voice, owner, key)
    local slot = M.find(voice, owner, key)
    if not slot then return false end
    if slot > 1 then
      release_slot(voice, slot)
    else
      forget(slots[voice][1], util.time())
      held_changed()
    end
    return true
  end

  -- Forget every note of voice, parked included, sending nothing: for a
  -- voice the engine has stopped (voiceOff ends all its notes)
  function M.release_all(voice)
    if not whole_in(voice, 1, NUM_VOICES) then return end
    local held_before, now = M.held(voice), util.time()
    for slot = 1, NOTE_SLOTS do
      if slots[voice][slot] then forget(slots[voice][slot], now) end
    end
    lowered[voice] = nil
    if held_before > 0 then held_changed() end
  end

  -- A held note's expression: values' keys (bend, amp, position, size,
  -- main; each finite number clipped to its range) replace the note's, the
  -- rest kept, and the note is due for the flush. false when slot of voice
  -- holds no note
  function M.set_expression(voice, slot, values)
    if not whole_in(voice, 1, NUM_VOICES) or not whole_in(slot, 1, NOTE_SLOTS) then return false end
    local record = slots[voice][slot]
    if not record or not record.held then return false end
    record.expression = merged_expression(record.expression, values)
    mark_due(record)
    return true
  end

  -- A copy of the expression slot of voice holds ({bend, amp, position,
  -- size, main}: the newest set, sent or still due), or nil for a slot
  -- holding no note or a bad index (ruling 36: lib/expression.lua compares
  -- a note's values with it)
  function M.expression(voice, slot)
    if not whole_in(voice, 1, NUM_VOICES) or not whole_in(slot, 1, NOTE_SLOTS) then return nil end
    local record = slots[voice][slot]
    if not record then return nil end
    return copy_expression(record.expression)
  end

  -- 3.7: the notes whose time is up (to_end) end: an extra note is released
  -- (noteOff), the own note's record goes with nothing sent (a one-shot
  -- slice is silent past its end), so every note started ends once
  local function end_due_notes()
    local now = util.time()
    for voice = 1, NUM_VOICES do
      for slot = 1, NOTE_SLOTS do
        local record = slots[voice][slot]
        if record and record.held and record.ends_at and now >= record.ends_at then
          if slot > 1 then
            release_slot(voice, slot)
          else
            forget(record, now)
            held_changed()
          end
        end
      end
    end
  end

  -- The flush (an LFO step hook): the due notes in the order first marked,
  -- at most NOTES.sends_per_step, each once with its newest values; a note
  -- that ended meanwhile sends nothing, and the rest wait for the next step

  local function flush_step()
    if flush.stopped then return end
    end_due_notes()
    local waiting, messages = {}, 0
    for _, record in ipairs(flush.queue) do
      if record.due and record.held and slots[record.voice][record.slot] == record then
        if messages < NOTES.sends_per_step then
          record.due = false
          send_expression(record.voice, record.slot, record.expression)
          messages = messages + 1
        else
          table.insert(waiting, record)
        end
      end
    end
    flush.queue = waiting
    count(messages)
  end

  -- The flush ends (cleanup): nothing is due, nothing is sent after it
  function M.stop_flush()
    flush.stopped = true
    for _, record in ipairs(flush.queue) do record.due = false end
    flush.queue = {}
  end

  -- Set the pool, a whole number clamped to 0..NOTE_POOL.max: notes.data is
  -- written first, so a write that fails sets nothing (false), as
  -- S.lib.grid_core.set_rotation does. Then the newest held extra notes past
  -- a smaller pool are released and the engine gets setNotePool; true.
  -- false for anything but a whole number
  function M.set_pool(n)
    if not finite(n) or n % 1 ~= 0 then return false end
    n = util.clamp(n, 0, NOTE_POOL.max)
    util.make_dir(_path.data .. "strata/")
    local written, problem = S.lib.data_files.write(notes_path(), {version = NOTES.version, pool = n})
    if not written then
      print("strata: " .. NOTES.file .. " not saved: " .. tostring(problem))
      return false
    end
    pool_setting = n
    while M.pool_used() > n do
      local newest
      for voice = 1, NUM_VOICES do
        for slot = 2, NOTE_SLOTS do
          local record = slots[voice][slot]
          if record and (newest == nil or record.started >= newest.started) then newest = record end
        end
      end
      release_slot(newest.voice, newest.slot)  -- by slot: the loop always frees one
    end
    engine.setNotePool(n)
    return true
  end

  -- The note cap (v<i>_note_cap, 1-NOTE_SLOTS, default NOTE_SLOTS): a
  -- registered voice param in VOICE's notes section, PSET only. Lowering it
  -- under held notes keeps them. VOICE's layout tests and renders draw its
  -- row under the cursor on every voice
  local cap_layout_states = {}
  local function add_layout_state(voice, key, name)
    table.insert(cap_layout_states, {
      name = string.format("v%d %s", voice, name),
      setup = function()
        S.selected_voice = voice
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v" .. voice .. "_" .. key))
      end,
    })
  end
  for voice = 1, NUM_VOICES do
    add_layout_state(voice, NOTES.cap.key, NOTES.cap.name)
    for _, key in ipairs(NOTES.envelope_keys) do add_layout_state(voice, key, key) end
  end

  -- The envelope times (v<i>_attack, v<i>_release, seconds, exponential,
  -- default the voice def's): voice params the engine takes with
  -- setVoiceParam (attackTime, releaseTime), not grain params. They are
  -- scene fields (a crossfade), and no randomize draws them. voiceOn resets
  -- them: a start sends both after it (the grain-restart hook below), a
  -- sync of a running voice through the record's sync, a turn through the
  -- sender (running voices only)
  local function send_envelope(voice)
    local values = S.voices[voice].values
    for _, key in ipairs(NOTES.envelope_keys) do
      engine.setVoiceParam(voice - 1, NOTES.envelope_engine[key], values[key])
    end
  end
  local cap_record
  cap_record = {
    name = "notes",
    count = 1 + #NOTES.envelope_keys,
    add = function(voice)
      S.lib.params_setup.add_voice_param(voice, cap_record, NOTES.cap.key, {
        type = "number", name = NOTES.cap.name, min = 1, max = NOTE_SLOTS, default = NOTE_SLOTS,
        -- a number param's own string is its number (norns' Number:string)
        formatter = function(param) return tostring(param:get()) end,
        action = function() update_lowered(voice) end,
      })
      for index, key in ipairs(NOTES.envelope_keys) do
        local range = NOTES.envelope_ranges[key]
        S.lib.params_setup.add_voice_param(voice, cap_record, key, {
          type = "control", name = key,
          controlspec = controlspec.new(range[1], range[2], "exp", 0, NOTES.envelope[voice][index], "s"),
        })
        S.lib.engine_sync.add_voice_sender(voice, "v" .. voice .. "_" .. key, function(value)
          engine.setVoiceParam(voice - 1, NOTES.envelope_engine[key], value)
        end)
      end
    end,
    -- a running voice's sync (a start sends them after voiceOn instead)
    sync = function(voice)
      if S.voices[voice].active then send_envelope(voice) end
    end,
    -- each voice's own times (a function of the voice): a scene without
    -- them gets the voice's defaults (fill_scene)
    scene_defaults = function(voice)
      return {attack = NOTES.envelope[voice][1], release = NOTES.envelope[voice][2]}
    end,
    scene_ranges = {attack = NOTES.envelope_ranges.attack, release = NOTES.envelope_ranges.release},
    voice_rows = {section = NOTES.cap.section, rows = {NOTES.cap.key, "attack", "release"}, before = NOTES.cap.before},
    layout_states = cap_layout_states,
    fader = {{keys = {"attack", "release"}, rank = 4}},
  }
  S.register_voice_params(cap_record)

  -- After voiceOn (which resets them), every start and every source change
  -- of a running voice sends both times
  S.register_grain_restart(send_envelope)

  -- The start step: read notes.data (parsed, never run). A version
  -- NOTES.version file whose pool is a whole number in 0..NOTE_POOL.max
  -- sets the pool; no file leaves the tier's default, and so does anything
  -- else (text that does not parse, another version, a bad pool), with one
  -- console line, and that file is set aside (notes.data.bak, ...) as
  -- io.data is; one that cannot be set aside stays, and the next set_pool
  -- writes over it. Then the engine gets the pool, and the flush joins the
  -- LFO clock's step hooks (after those registered at include time)
  S.register_start(S.constants.START_ORDER.notes_load, function()
    pool_setting = nil
    local path = notes_path()
    local value, problem, why = S.lib.data_files.read(path)
    if type(value) == "table" and value.version == NOTES.version and whole_in(value.pool, 0, NOTE_POOL.max) then
      pool_setting = value.pool
    elseif value ~= nil or problem == "unreadable" then
      local backup, failure = S.lib.data_files.set_aside(path, NOTES.backup_suffix)
      print("strata: " .. NOTES.file .. " not used (" .. tostring(why or "not a note pool setting")
        .. "): the pool is the tier's default, " .. tier_default() .. "; "
        .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure))))
    end
    engine.setNotePool(M.pool())
    flush.stopped = false
    if not flush.hooked then
      flush.hooked = true
      S.lib.lfos.on_step(flush_step)
    end
  end)

  -- The cleanup step: the flush ends
  S.register_cleanup(S.constants.CLEANUP_ORDER.notes, function() M.stop_flush() end)

  -- A stopped voice's notes are forgotten (whoever stopped it); its next
  -- start resets slot 0's expression in the engine
  S.register_voice_stop(function(voice)
    M.release_all(voice)
    sent[voice][1] = copy_expression(NOTES.neutral)
    references[voice] = nil  -- a stopped voice keeps no freeze reference
    -- 3.7: no own region. The extra slots' regions are the engine's still
    -- (it keeps them across a stop; only alloc and the area's stop clear
    -- them), so regions_sent keeps them too
    own_regions[voice] = nil
  end)

  -- A voice that becomes a frozen synth voice: its extra notes cut
  -- (noteOff with cut 1, in slot order) and forgotten, their sound in the
  -- frozen ring; then, when any went, the held count's redraws and the own
  -- note's return if it was parked under them (ruling 39)
  local function cut_extras(voice)
    local now, cut = util.time(), 0
    for slot = 2, NOTE_SLOTS do
      if slots[voice][slot] then
        engine.noteOff(voice - 1, slot - 1, 1)
        forget(slots[voice][slot], now)
        cut = cut + 1
      end
    end
    count(cut)
    if cut > 0 then
      update_lowered(voice)
      held_changed()
      unpark_alone(voice, now)  -- ruling 39: the cuts may have taken the voice's last held note
    end
  end

  -- Every start (after its voiceOn, the voice not yet marked running) and
  -- every running voice's source change, a recall's included: a fresh
  -- freeze reference. At a start only, a frozen synth voice's own note gets
  -- its rate on the new own grain synth: noteOn on slot 0 from slot 1's held
  -- note, a quiet note whose caller starts the voice now (a play that starts
  -- the voice writes its record after the start, and sends that noteOn
  -- itself). A running voice's source switch sends nothing (design §2.4: a
  -- source switch needs nothing from Lua; the source is sent before the
  -- freeze module's hook unfreezes the voice, and slot 1's pitch was its old
  -- source's; a recall's switch is settled at the recall's end, below). With
  -- the voice-stop hook this covers every start and source change: a stopped
  -- voice's switch runs no hook, and a stopped voice keeps no reference
  S.register_grain_restart(function(voice)
    refresh_reference(voice, true)
    -- 3.7: a running voice's source switch: its regions were the old
    -- slot's (the sync that follows sends the own region's clear)
    if S.voices[voice].active then
      own_regions[voice] = nil
      end_extra_regions(voice)
    end
    local record = slots[voice][1]
    if not S.voices[voice].active and record and record.held and frozen_synth(voice) then
      send_note_on(voice, 1, record)
      count(1)
    end
  end)

  -- Rulings 58 and 59 (#690): a running voice whose source a recall switched
  -- (lib/scenes.lua's apply_entries calls this for each, once every entry is
  -- applied: an instant recall, a fade's landing, a morph's discrete
  -- switches). What the voice is then decides: a frozen synth voice has its
  -- extra notes cut and forgotten, as a freeze does (the switch restarted
  -- them as voice synths under the frozen ring, and with the freeze already
  -- on no freeze hook ran); any other keeps them (the engine restarted them,
  -- sounding, on the new source). A voice outside 1..NUM_VOICES, or stopped,
  -- is left alone
  function M.recall_switched(voice)
    if whole_in(voice, 1, NUM_VOICES) and S.voices[voice].active and frozen_synth(voice) then cut_extras(voice) end
  end

  -- A synth voice's freeze: its reference taken, its extra notes cut and
  -- forgotten (their sound is in the frozen ring); scaleNote resent (the
  -- reference while frozen, the freq's note after)
  S.register_freeze_change(function(voice, frozen)
    refresh_reference(voice, frozen and S.voices[voice].active)  -- a stopped voice's start takes it
    if not voice_uses_synth(voice) then return end
    if frozen then cut_extras(voice) end
    S.lib.variation.send_scale_note(voice, S.lib.engine_sync.engine_base_value("v" .. voice .. "_freq"))
  end)

  -- A slot record's problem (nil: whole)
  local function record_problem(record, voice, slot)
    if record.voice ~= voice or record.slot ~= slot then return "the record names another slot" end
    if NOTES.owners[record.owner] ~= true or record.key == nil then return "no owner and key" end
    if not finite(record.pitch) or not finite(record.started) then return "no pitch or start" end
    if not (finite(record.velocity) and record.velocity >= 0 and record.velocity <= 1) then return "a bad velocity" end
    if type(record.held) ~= "boolean" or record.parked == record.held then return "neither held nor parked" end
    if type(record.quiet) ~= "boolean" then return "no quiet flag" end
    if record.parked and slot ~= 1 then return "an extra note is parked" end
    for _, key in ipairs(NOTES.expression_keys) do
      local value, range = record.expression[key], NOTES.expression_ranges[key]
      if not (finite(value) and value >= range[1] and value <= range[2]) then return "a bad " .. key end
    end
  end

  -- The pool is a whole number in 0..NOTE_POOL.max and the held extra notes
  -- never exceed it; every slot record is whole; a voice's used slots are
  -- under its cap unless it was lowered under them; a stopped voice holds no
  -- extra note, and its slot 1 at most a held quiet note awaiting its
  -- caller's start; a voice holds each owner and key once (so slot 1's
  -- holder is one owner and key); a running voice with no held note keeps
  -- no parked own note (ruling 39)
  S.register_invariant("notes", function()
    local pool = M.pool()
    if not whole_in(pool, 0, NOTE_POOL.max) then
      return "the pool is " .. tostring(pool) .. ", not a whole number in 0.." .. NOTE_POOL.max
    end
    if M.pool_used() > pool then return M.pool_used() .. " extra notes are held, past the pool's " .. pool end
    for voice = 1, NUM_VOICES do
      local held = {}
      for slot = 1, NOTE_SLOTS do
        local record = slots[voice][slot]
        if record then
          local problem = record_problem(record, voice, slot)
          if problem then return "voice " .. voice .. " slot " .. slot .. ": " .. problem end
          if not S.voices[voice].active and (slot > 1 or not (record.quiet and record.held)) then
            return "stopped voice " .. voice .. " holds " .. (slot > 1 and "an extra note" or "a note not quiet")
              .. " in slot " .. slot
          end
          if slot > note_cap(voice) and not lowered[voice] then
            return "voice " .. voice .. " holds slot " .. slot .. " past its cap of " .. note_cap(voice)
          end
          if record.parked and S.voices[voice].active and M.held(voice) == 0 then
            return "running voice " .. voice .. " holds no note but keeps its own note parked"
          end
          for _, other in ipairs(held) do
            if record.held and other.owner == record.owner and other.key == record.key then
              return "voice " .. voice .. " holds " .. record.owner .. " key " .. tostring(record.key) .. " twice"
            end
          end
          if record.held then table.insert(held, record) end
        end
      end
    end
  end)

  return M
end

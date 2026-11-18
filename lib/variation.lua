-- lib/variation.lua
-- Per-grain variation and scales. Twelve registered voice params per voice
-- (S.register_voice_params): reverse, pitch, pan and size jitter, an
-- interval set with its probability and five custom intervals, and
-- quantize; the global scale and root (discrete scene fields, sent with
-- engine.setScale); scaleNote, the voice's reference note for grain
-- quantize; and the freq param filter that keeps a quantized voice's freq
-- on the scale as it is turned. MAIN's randomize and mutation never touch
-- any of it; the fader pages show the pitch, size and pan jitters (the
-- record's fader group, rank 3), no other variation param; VOICE's ALT+K2
-- on its section draws some (the record's randomize, #557). See
-- docs/notes/lua/variation.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local musicutil = require "musicutil"

  -- The variation constants, in one table
  M.VARIATION = {
    section = "variation",             -- VOICE: a section of its own, after mix
    interval_sets = {"off", "octaves", "fifths", "chord", "custom"},
    set_index = {off = 1, octaves = 2, fifths = 3, chord = 4, custom = 5},
    octaves = {-12, 0, 12},
    fifths = {-12, -5, 0, 7, 12},
    chord_degrees = {1, 3, 5, 7},      -- the scale's degrees a chord takes, from the root
    chromatic_chord = {0, 4, 7, 11},   -- the chord with the scale off
    custom_defaults = {-12, 0, 7, 12, 19},
    custom_range = 24,                 -- custom intervals: -24..24 semitones
    max_intervals = 8,                 -- the engine's interval1..8
    percent = 100,                     -- reverse and interval probability are percentages
    pitch_jitter_max = 12,             -- semitones
    chromatic_mask = 4095,             -- every pitch class: quantize to semitones
    reference_octave = 60,             -- buffer and input voices: scaleNote is root + 60
    semitones = 12,
    a4_note = 69, a4_freq = 440,
    -- 3.8: the scale held as a mask (scale_mask), the last scale option,
    -- tested for by name (ruling 39); the mask's range
    custom_scale = "custom", mask_range = {1, 4095},
  }
  local V = M.VARIATION

  -- The global scale options: off, then musicutil's scales by name, then
  -- custom (3.8: appended, so no saved index moves)
  function M.scale_options()
    local options = {"off"}
    for _, scale in ipairs(musicutil.SCALES) do table.insert(options, scale.name) end
    table.insert(options, V.custom_scale)
    return options
  end

  -- Whether the scale param picks custom (by its name, ruling 39)
  function M.scale_is_custom()
    local param = params:lookup_param("scale")
    return param.options[params:get("scale")] == V.custom_scale
  end

  -- The musicutil scale the scale param picks, or nil while it is off or
  -- custom
  local function current_scale()
    local index = params:get("scale")
    if index <= 1 or M.scale_is_custom() then return nil end
    return musicutil.SCALES[index - 1]
  end

  -- The root as a pitch class, 0 (C) to 11
  function M.root()
    return params:get("root") - 1
  end

  -- The scale as a 12-bit pitch-class set from the root (bit k: k semitones
  -- above it); the chromatic mask while the scale is off
  -- (arithmetic, not Lua 5.3's bit operators: the tests also run on LuaJIT)
  function M.scale_mask()
    if M.scale_is_custom() then return params:get("scale_mask") end
    local scale = current_scale()
    if not scale then return V.chromatic_mask end
    local classes, mask = {}, 0
    for _, interval in ipairs(scale.intervals) do classes[interval % V.semitones] = true end
    for pitch_class in pairs(classes) do mask = mask + 2 ^ pitch_class end
    return math.floor(mask)
  end

  -- Whether a scale is on (the scale param not off)
  function M.scale_on()
    return params:get("scale") > 1
  end

  -- The allowed tone nearest a MIDI note (fractional or whole; a tie goes
  -- down): the tuning's snap (S.lib.tuning.snap, 3.8)
  function M.snap_note(note)
    return S.lib.tuning.snap(note)
  end

  local function freq_to_note(freq) return V.a4_note + V.semitones * math.log(freq / V.a4_freq) / math.log(2) end
  local function note_to_freq(note) return musicutil.note_num_to_freq(note) end

  -- Whether voice voice_idx quantizes (v<i>_quantize on)
  function M.quantizes(voice_idx)
    local voice = S.voices[voice_idx]
    return voice ~= nil and voice.values ~= nil and voice.values.quantize == 1
  end

  -- The voice's reference note for grain quantize (scaleNote): a synth
  -- voice's freq (freq, or its stored freq) as a fractional MIDI note; for a
  -- buffer voice whose file's key is set (3.7), the key
  -- (S.lib.samples.scale_reference); for any other buffer or input voice,
  -- whose content's key is unknown, the root + 60.
  -- A frozen synth voice's is its freeze reference whatever freq is passed
  -- (3.5: S.lib.notes.freeze_reference), so no resend moves it
  function M.scale_note(voice_idx, freq)
    if voice_uses_synth(voice_idx) then
      local reference = S.lib.notes and S.lib.notes.freeze_reference(voice_idx)
      if reference then return reference end
      return freq_to_note(freq or S.voices[voice_idx].values.freq)
    end
    return S.lib.samples.scale_reference(voice_idx) or M.root() + V.reference_octave
  end

  -- Send scaleNote to a running voice (freq: the value about to be stored)
  function M.send_scale_note(voice_idx, freq)
    if voice_idx < 1 or voice_idx > NUM_VOICES or not S.voices[voice_idx].active then return end
    engine.setGrainParam(voice_idx - 1, "scaleNote", M.scale_note(voice_idx, freq))
  end

  -- Send rootNote to a running voice: the note that plays rate 1 on it
  -- (3.7: S.lib.samples.rate_root, its file's key or 60), for a note the
  -- engine restarts on a buffer
  function M.send_root_note(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES or not S.voices[voice_idx].active then return end
    engine.setGrainParam(voice_idx - 1, "rootNote", S.lib.samples.rate_root(voice_idx))
  end

  -- The semitones of the voice's interval set (empty while it is off)
  function M.interval_set(voice_idx)
    local values = S.voices[voice_idx].values
    local set = values.intervals
    if set == V.set_index.octaves then return V.octaves end
    if set == V.set_index.fifths then return V.fifths end
    -- the chord: the tuning's (3.8 ruling 40: a scale's degrees 1, 3, 5
    -- and 7 in twelve tones to an octave, else its tones nearest 0, 4, 7, 11)
    if set == V.set_index.chord then return S.lib.tuning.chord() end
    if set == V.set_index.custom then
      local custom = {}
      for index = 1, #V.custom_defaults do table.insert(custom, values["custom_interval_" .. index]) end
      return custom
    end
    return {}
  end

  -- interval1..8 (0 past the list) and intervalCount, always: the list the
  -- arpeggiator orders (3.8, S.lib.arp.list: the set as it is while it is
  -- off, else the set or the held chord in the mode's order)
  local function send_intervals_now(voice_idx)
    local set = S.lib.arp.list(voice_idx, M.interval_set(voice_idx))
    for index = 1, V.max_intervals do
      engine.setGrainParam(voice_idx - 1, "interval" .. index, set[index] or 0)
    end
    engine.setGrainParam(voice_idx - 1, "intervalCount", math.min(#set, V.max_intervals))
    S.lib.arp.sent(voice_idx, set)  -- what the engine holds now: an unchanged list is never sent again
  end

  -- The voice's interval set, while it runs
  function M.send_intervals(voice_idx)
    if S.voices[voice_idx].active then send_intervals_now(voice_idx) end
  end

  -- The scale to the engine: setScale(root, mask)
  function M.send_scale()
    engine.setScale(M.root(), M.scale_mask())
  end

  -- The freq of the allowed tone nearest a note, inside the voice's freq
  -- range (the nearest tone inside it at either end: the tuning's snap,
  -- then its steps, 3.8)
  local function tone_freq(voice_idx, note)
    local low, high = param_range("v" .. voice_idx .. "_freq")
    local tuning = S.lib.tuning
    local tone = tuning.snap(note)
    while note_to_freq(tone) > high do tone = tuning.step(tone, -1) end
    while note_to_freq(tone) < low do tone = tuning.step(tone, 1) end
    return note_to_freq(tone)
  end

  -- How far a turn moves the shadow for each semitone of raw travel (3.8
  -- ruling 41): min(1, the allowed tones' mean step / one detent's travel),
  -- the detent's travel from the freq spec (its quantum of the range, in
  -- semitones), so a dense tuning turns about one tone a detent and twelve
  -- equal steps and every built-in scale (a mean step of a semitone or
  -- more against 0.8) turn as before
  local function turn_scale(voice_idx)
    local low, high = param_range("v" .. voice_idx .. "_freq")
    local quantum = params:lookup_param("v" .. voice_idx .. "_freq").controlspec.quantum
    local detent = quantum * (freq_to_note(high) - freq_to_note(low))
    return math.min(1, S.lib.tuning.mean_step() / detent)
  end

  -- The freq filter's state per voice: shadow[i], the unsnapped note the
  -- turns have reached, and returned[i], the freq the filter last returned
  -- (nil: no turn under way)
  local shadow, returned = {}, {}

  -- A quantized voice's freq. A turn (turned: an encoder detent, an arc
  -- tick, the PARAMS menu's own delta or a mutation step, marked in
  -- S.turning_param, #318) moves the unsnapped shadow note by the change of
  -- the incoming value from the stored one, and the freq is the scale tone
  -- nearest the shadow, so a detent or arc tick of a fraction of a semitone
  -- still adds up to about one scale tone per semitone of travel. Every
  -- other set (a scene fade step, a mapped CC, a fader, a MIDI note, a
  -- script's set) is a value in its own right, however near the stored
  -- one: the shadow starts again from it, so a fade or a CC sweep moves one
  -- way only. The shadow also starts again when the stored value is not
  -- what the filter last returned (something else set it). A scene recall's
  -- values stand as saved. Every change sends scaleNote (the value settled)
  local function freq_filter(voice_idx, value, previous, turned)
    local result = value
    if M.quantizes(voice_idx) and not S.scene_recall_in_progress then
      local low, high = param_range("v" .. voice_idx .. "_freq")
      local note = freq_to_note(value)
      if turned and shadow[voice_idx] ~= nil and previous ~= nil and previous == returned[voice_idx] then
        shadow[voice_idx] = shadow[voice_idx] + (note - freq_to_note(previous)) * turn_scale(voice_idx)
      else
        shadow[voice_idx] = note
      end
      shadow[voice_idx] = util.clamp(shadow[voice_idx], freq_to_note(low), freq_to_note(high))
      result = tone_freq(voice_idx, shadow[voice_idx])
      returned[voice_idx] = result
    else
      shadow[voice_idx], returned[voice_idx] = nil, nil
    end
    M.send_scale_note(voice_idx, result)
    return result
  end
  S.register_param_filter("freq", freq_filter)

  -- Snap a voice's stored freq to the scale (quantize turned on): set
  -- through the param, so the filter starts its shadow there
  local function snap_freq(voice_idx)
    shadow[voice_idx], returned[voice_idx] = nil, nil
    local param_id = "v" .. voice_idx .. "_freq"
    params:set(param_id, tone_freq(voice_idx, freq_to_note(S.voices[voice_idx].values.freq)))
  end

  -- The pitch a MIDI key plays on a voice: the key's pitch in the tuning
  -- (S.lib.tuning.pitch_of_key, 3.8; the key itself in twelve equal
  -- steps), snapped to the nearest allowed tone on a quantized voice
  function M.midi_note(voice_idx, key)
    local pitch = S.lib.tuning.pitch_of_key(key)
    if M.quantizes(voice_idx) then return S.lib.tuning.snap(pitch) end
    return pitch
  end

  -- VOICE's layout tests and page renders: every voice with the custom
  -- set and its widest values, on each kind of source in turn (synth,
  -- buffer, input), its cursor on interval prob (the rows above it in view)
  -- and on the last custom row
  local layout_sources = {S.constants.SOURCE_SYNTH, S.constants.SOURCE_SYNTH + 1, S.constants.SOURCE_INPUT}
  local layout_states = {}
  for voice_idx = 1, NUM_VOICES do
    local source = layout_sources[(voice_idx - 1) % #layout_sources + 1]
    local prefix = "v" .. voice_idx .. "_"
    for _, cursor_key in ipairs({"interval_prob", "custom_interval_" .. #V.custom_defaults}) do
      table.insert(layout_states, {
        name = string.format("v%d variation %s (source %d)", voice_idx, cursor_key, source),
        setup = function()
          S.selected_voice = voice_idx
          params:set(prefix .. "source", source)
          params:set(prefix .. "intervals", V.set_index.custom)
          params:set(prefix .. "reverse", V.percent)
          params:set(prefix .. "pitch_jitter", V.pitch_jitter_max)
          params:set(prefix .. "pan_jitter", 1)
          params:set(prefix .. "size_jitter", 1)
          params:set(prefix .. "interval_prob", V.percent)
          params:set(prefix .. "custom_interval_" .. #V.custom_defaults, -V.custom_range)
          S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(prefix .. cursor_key))
        end,
      })
    end
  end

  local function percent_fraction(x) return x / V.percent end
  local function semitones_text(param) return param:get() .. " st" end

  local scene_defaults = {reverse = 0, pitch_jitter = 0, pan_jitter = 0, size_jitter = 0,
    intervals = V.set_index.off, interval_prob = V.percent, quantize = 0}
  local discrete = {intervals = {1, #V.interval_sets}, quantize = {0, 1}}
  local rows = {"reverse", "pitch_jitter", "pan_jitter", "size_jitter", "intervals", "interval_prob"}
  for index, default in ipairs(V.custom_defaults) do
    local key = "custom_interval_" .. index
    scene_defaults[key] = default
    discrete[key] = {-V.custom_range, V.custom_range}
    table.insert(rows, key)
  end
  table.insert(rows, "quantize")

  local record
  record = {
    name = "variation",
    count = #rows,  -- one param per VOICE row
    add = function(voice_idx)
      local add = S.lib.params_setup.add_voice_param
      add(voice_idx, record, "reverse", {type = "control", name = "reverse",
        controlspec = controlspec.new(0, V.percent, "lin", 1, 0, "%")})
      add(voice_idx, record, "pitch_jitter", {type = "control", name = "pitch jitter",
        controlspec = controlspec.new(0, V.pitch_jitter_max, "lin", 0.1, 0, "st")})
      add(voice_idx, record, "pan_jitter", {type = "control", name = "pan jitter",
        controlspec = controlspec.new(0, 1, "lin", 0.01, 0)})
      add(voice_idx, record, "size_jitter", {type = "control", name = "size jitter",
        controlspec = controlspec.new(0, 1, "lin", 0.01, 0)})
      add(voice_idx, record, "intervals", {type = "option", name = "intervals", options = V.interval_sets,
        default = V.set_index.off, action = function() M.send_intervals(voice_idx) end})
      add(voice_idx, record, "interval_prob", {type = "control", name = "interval prob",
        controlspec = controlspec.new(0, V.percent, "lin", 1, V.percent, "%")})
      for index, default in ipairs(V.custom_defaults) do
        add(voice_idx, record, "custom_interval_" .. index, {type = "number", name = "custom " .. index,
          min = -V.custom_range, max = V.custom_range, default = default, formatter = semitones_text,
          action = function()
            if S.voices[voice_idx].values.intervals == V.set_index.custom then M.send_intervals(voice_idx) end
          end})
      end
    end,
    -- quantize ahead of the voice's freq, so a PSET (read in param order)
    -- sets it before the freq the filter snaps by it (#125)
    add_first = function(voice_idx)
      S.lib.params_setup.add_voice_param(voice_idx, record, "quantize", {type = "binary", name = "quantize",
        behavior = "toggle", default = 0,
        action = function(x)
          if x == 1 and not S.scene_recall_in_progress then snap_freq(voice_idx) end
          M.send_scale_note(voice_idx)
        end})
    end,
    grain_keys = {
      reverse = {name = "reverseProb", value = percent_fraction},
      pitch_jitter = "pitchJitter",
      pan_jitter = "panJitter",
      size_jitter = "sizeJitter",
      interval_prob = {name = "intervalProb", value = percent_fraction},
      quantize = "quantize",
    },
    -- the voice sync (the voice may not be marked running yet): the
    -- interval set and the reference note, from the freq the engine plays (a
    -- step's note, set before the start it makes, #632), and the root note
    -- (3.7)
    sync = function(voice_idx)
      send_intervals_now(voice_idx)
      engine.setGrainParam(voice_idx - 1, "scaleNote",
        M.scale_note(voice_idx, S.lib.engine_sync.engine_base_value("v" .. voice_idx .. "_freq")))
      engine.setGrainParam(voice_idx - 1, "rootNote", S.lib.samples.rate_root(voice_idx))
    end,
    scene_defaults = scene_defaults,
    discrete = discrete,
    voice_rows = {
      section = V.section,
      rows = rows,
      -- the custom intervals only for the custom set
      when = function(voice_idx, key)
        return not key:match("^custom_interval_") or S.voices[voice_idx].values.intervals == V.set_index.custom
      end,
    },
    layout_states = layout_states,
    fader = {{keys = {"pitch_jitter", "size_jitter", "pan_jitter"}, rank = 3}},
    -- VOICE's ALT+K2 on this section (#557): each draw uniform over a usable
    -- part of its range. The interval set, the custom intervals and
    -- quantize are kept: they set the pitch content, and the set adds or
    -- removes rows under the cursor
    randomize = {
      reverse = function() return math.random() * V.percent / 2 end,
      pitch_jitter = function() return math.random() * V.pitch_jitter_max / 2 end,
      pan_jitter = function() return math.random() * 0.5 end,
      size_jitter = function() return math.random() * 0.5 end,
      interval_prob = function() return math.random() * V.percent end,
    },
  }
  S.register_voice_params(record)

  -- A source change moves a buffer or input voice's reference to the root
  S.register_source_change(function(voice_idx) M.send_scale_note(voice_idx) end)

  -- Every quantized voice's stored freq onto the scale (a scale, root or
  -- tuning change), so the freq a PSET or scene captures is a tone of it;
  -- never during a scene recall or transition, whose values stand as saved
  function M.snap_quantized_freqs()
    if S.scene_recall_in_progress or S.scene_transition_active then return end
    for voice_idx = 1, NUM_VOICES do
      if M.quantizes(voice_idx) then snap_freq(voice_idx) end
    end
  end
  local snap_quantized_freqs = M.snap_quantized_freqs

  -- Every running chord voice's intervals again (a scale or tuning change)
  local function send_chords()
    for voice_idx = 1, NUM_VOICES do
      if S.voices[voice_idx].values.intervals == V.set_index.chord then M.send_intervals(voice_idx) end
    end
  end

  -- The tuning changed (S.lib.tuning.apply_text, 3.8): every quantized freq
  -- snapped to it and every chord resent
  function M.tuning_changed()
    snap_quantized_freqs()
    send_chords()
  end

  -- The global scale and root (PARAMS, before the voices, so a PSET sets
  -- the scale before any quantized freq): their actions send setScale and
  -- snap every quantized freq to the new scale; a scale change also resends
  -- every chord, a root change every running voice's scaleNote
  function M.add_scale_params()
    params:add_separator("strata_scale", "scale")
    params:add{type = "option", id = "scale", name = "scale", options = M.scale_options(), default = 1,
      action = function()
        M.send_scale()
        snap_quantized_freqs()
        send_chords()
      end}
    params:add{type = "option", id = "root", name = "root", options = musicutil.NOTE_NAMES, default = 1,
      action = function()
        M.send_scale()
        snap_quantized_freqs()
        for voice_idx = 1, NUM_VOICES do M.send_scale_note(voice_idx) end
      end}
    -- 3.8: the custom scale's mask, which acts only while the scale is
    -- custom (so a scale or root change still sends one setScale)
    params:add{type = "number", id = "scale_mask", name = "scale mask", min = V.mask_range[1], max = V.mask_range[2],
      default = V.chromatic_mask,
      action = function()
        if not M.scale_is_custom() then return end
        M.send_scale()
        snap_quantized_freqs()
        send_chords()
      end}
    -- 3.8: the tuning's two text params (lib/tuning.lua), still before every voice
    S.lib.tuning.add_params()
  end

  -- Both are discrete scene globals: a transition switches them at its end
  S.register_scene_field({id = "scale", default = 1, discrete = true})
  S.register_scene_field({id = "root", default = 1, discrete = true})
  -- 3.8: the custom scale's mask, a discrete scene global beside them
  S.register_scene_field({id = "scale_mask", default = V.chromatic_mask, discrete = true})

  return M
end

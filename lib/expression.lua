-- lib/expression.lua
-- Expression (3.5, design §6), S.lib.expression: per voice, pressure and
-- slide each drive a target (v<i>_press_target, v<i>_slide_target: off,
-- amp, level, main, size, density, position, cutoff) by a depth
-- (v<i>_press_depth, v<i>_slide_depth, -100..100 %): a registered voice-
-- params record "expression", rows of VOICE's notes section after the note
-- cap, scene keys (the targets discrete) and PSET params, with a migration
-- for scenes older than format 7. note_values(voice, raw) turns a note's
-- {bend, pressure, slide} (slide relative) into the five values of its
-- noteExpression; update(voice, owner, key, raw) keeps a held note's
-- controller values (its slide measured from the touch's first) and hands
-- them to S.lib.notes.set_expression; latch keeps a note's highest
-- pressure; forget starts a new touch. A step hook on the LFO clock hands
-- the voice-wide targets (cutoff, density, a synth voice's size) the
-- largest value among a voice's held notes, and forgets the notes the
-- allocator no longer holds. Registers the sixteen sources PRES, SLID,
-- PR1..PR7 and SL1..SL7 (section notes). Sends no engine command itself.
-- See docs/notes/lua/expression.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The module's tunables: the targets (the option order: stored in
  -- scenes and PSETs, so it never changes), the two mappings (their param
  -- keys, the controller value each reads and the defaults), the depth's
  -- range, the gain and offset clips, VOICE's section, the extra-offset
  -- key, the voice-wide targets' param suffixes, the sources' names and
  -- section and the scene format the migration fills
  local EXPRESSION = {
    targets = {"off", "amp", "level", "main", "size", "density", "position", "cutoff"},
    mappings = {
      {target_key = "press_target", depth_key = "press_depth", value = "pressure", name = "press",
        target = "amp", depth = 100},
      {target_key = "slide_target", depth_key = "slide_depth", value = "slide", name = "slide",
        target = "main", depth = 50},
    },
    depth_range = {-100, 100},
    gain_range = {0, 2},
    offset_range = {-1, 1},
    section = "notes", before = "variation",
    extra_key = "expression",
    wide_params = {cutoff = "filter_freq", size = "grain_size", density = "grain_density"},
    sources = {section = "notes", pressure = "PRES", slide = "SLID", voice_pressure = "PR", voice_slide = "SL"},
    scene_format = 7,
  }
  M.EXPRESSION = EXPRESSION

  local target_index = {}
  for index, name in ipairs(EXPRESSION.targets) do target_index[name] = index end

  local function valid_voice(voice)
    return type(voice) == "number" and voice % 1 == 0 and voice >= 1 and voice <= NUM_VOICES
  end

  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function clip(value, range) return util.clamp(value, range[1], range[2]) end

  local function param_id(voice, key) return "v" .. voice .. "_" .. key end

  local function neutral()
    return {bend = 1, amp = 1, position = 0, size = 0, main = 0}
  end

  local function same_values(a, b)
    return a.bend == b.bend and a.amp == b.amp and a.position == b.position and a.size == b.size and a.main == b.main
  end

  -- A mapping's target name and depth (a fraction, -1..1) on voice: the
  -- stored params (their defaults before the params exist)
  local function mapping_of(voice, mapping)
    local extras = S.voices[voice].extras or {}
    local target = EXPRESSION.targets[extras[mapping.target_key] or target_index[mapping.target]] or "off"
    local depth = extras[mapping.depth_key] or mapping.depth
    return target, depth / EXPRESSION.depth_range[2]
  end

  -- Where a target acts on voice now (design §6.3): "note" and the key of
  -- the note's values (amp for amp and level; main as the def's control on
  -- a synth voice, the position on a buffer voice, the size on an input
  -- voice), "wide" and the voice-wide target (cutoff, density, a synth
  -- voice's size), or nil (off: position on a voice that is not a buffer
  -- voice, main on a frozen synth voice, whose voice synths the ring no
  -- longer hears). A frozen synth voice's notes are streams: size per note
  local function placement(voice, target)
    if target == "amp" or target == "level" then return "note", "amp" end
    if target == "density" or target == "cutoff" then return "wide", target end
    local synth, buffer = voice_uses_synth(voice), voice_uses_buffer(voice)
    local frozen = synth and S.lib.freeze.is_frozen(voice)
    if target == "main" then
      if frozen then return nil end
      if synth then return "note", "main" end
      return "note", buffer and "position" or "size"
    elseif target == "size" then
      if synth and not frozen then return "wide", "size" end
      return "note", "size"
    elseif target == "position" and buffer then
      return "note", "position"
    end
    return nil
  end

  -- A gain (design §6.2, Question 12): amp a swell, 1 + depth x value;
  -- level the loudness, 1 - depth x (1 - value) above 0 and 1 + depth x
  -- value below; each clipped 0-2
  local function gain(target, depth, value)
    if target == "level" and depth > 0 then return clip(1 - depth * (1 - value), EXPRESSION.gain_range) end
    return clip(1 + depth * value, EXPRESSION.gain_range)
  end

  -- A note's values ({bend, amp, position, size, main}) and its voice-wide
  -- offsets ({cutoff, density, size} as m, half ranges) from relative =
  -- {bend, pressure, slide} (pressure 0-1 or nil: none yet, which leaves
  -- every target as stored; slide relative, -1..1, nil read as 0). Two
  -- mappings on one target multiply (gains) or add (offsets), each result
  -- clipped once more
  local function mapped(voice, relative)
    local values, wide = neutral(), {}
    values.bend = relative.bend
    for _, mapping in ipairs(EXPRESSION.mappings) do
      local value = relative[mapping.value]
      if value == nil and mapping.value == "slide" then value = 0 end
      local target, depth = mapping_of(voice, mapping)
      local kind, key = placement(voice, target)
      if value ~= nil and kind == "note" and key == "amp" then
        values.amp = clip(values.amp * gain(target, depth, value), EXPRESSION.gain_range)
      elseif value ~= nil and kind == "note" then
        values[key] = clip(values[key] + clip(depth * value, EXPRESSION.offset_range), EXPRESSION.offset_range)
      elseif value ~= nil and kind == "wide" then
        wide[key] = clip((wide[key] or 0) + clip(depth * value, EXPRESSION.offset_range), EXPRESSION.offset_range)
      end
    end
    return values, wide
  end

  local function bend_value(bend)
    if not finite(bend) then return 1 end
    local range = S.lib.notes.NOTES.expression_ranges.bend
    return clip(bend, range)
  end

  -- What a note plays for raw = {bend (a ratio), pressure (0-1, nil: none
  -- yet), slide (relative to the touch's first value, -1..1, nil: 0)}: the
  -- five values of its noteExpression, {bend, amp, position, size, main}.
  -- The voice-wide targets leave them neutral. nil for a voice outside
  -- 1..NUM_VOICES. The MIDI package gives a note's first expression from it
  function M.note_values(voice, raw)
    if not valid_voice(voice) then return nil end
    raw = type(raw) == "table" and raw or {}
    local relative = {bend = bend_value(raw.bend)}
    if finite(raw.pressure) then relative.pressure = util.clamp(raw.pressure, 0, 1) end
    if finite(raw.slide) then relative.slide = util.clamp(raw.slide, -1, 1) end
    return (mapped(voice, relative))
  end

  -- Per voice, the held notes this module keeps values for, each
  -- {owner, key, bend, pressure (nil until the first), peak (the highest
  -- of the touch), slide (absolute, nil until the first), reference (the
  -- touch's first slide), latched, values (what set_expression last got;
  -- neutral at first, as a note's first expression is without pressure)}
  local records = {}
  -- Per voice, the voice-wide values this module holds: cutoff and size
  -- (m, the matrix's fast extras), density (the extra offset, param
  -- units) and marked_density (the offset at the last send's mark)
  local wide_held = {}
  for voice = 1, NUM_VOICES do
    records[voice] = {}
    wide_held[voice] = {}
  end

  local function find_record(voice, owner, key)
    for index, record in ipairs(records[voice]) do
      if record.owner == owner and record.key == key then return record, index end
    end
    return nil
  end

  local function new_record(voice, owner, key)
    local record = {owner = owner, key = key, bend = 1, latched = false, values = neutral()}
    table.insert(records[voice], record)
    return record
  end

  local function relative_of(record)
    local relative = {bend = record.bend, pressure = record.pressure}
    if record.slide ~= nil then relative.slide = util.clamp(record.slide - record.reference, -1, 1) end
    return relative
  end

  -- The note's values to the allocator when they changed: it marks the
  -- note due for its flush, which sends them
  local function hand_over(voice, slot, record)
    local values, wide = mapped(voice, relative_of(record))
    if not same_values(values, record.values) then
      record.values = values
      S.lib.notes.set_expression(voice, slot, values)
    end
    return wide
  end

  -- A held note's controller values (design §6.2): raw = {bend (a ratio),
  -- pressure (0-1), slide (absolute, 0-1)}, each kept when nil. A note's
  -- first slide is its reference, so its first update moves nothing; a
  -- latched note changes no more. Then the note's values go to
  -- S.lib.notes.set_expression. true when they were taken; false for a
  -- note the allocator does not hold, a latched note or a bad argument
  function M.update(voice, owner, key, raw)
    if not valid_voice(voice) or type(raw) ~= "table" then return false end
    local slot = S.lib.notes.find(voice, owner, key)
    if not slot then return false end
    local record = find_record(voice, owner, key) or new_record(voice, owner, key)
    if record.latched then return false end
    if finite(raw.bend) then record.bend = bend_value(raw.bend) end
    if finite(raw.pressure) then
      local pressure = util.clamp(raw.pressure, 0, 1)
      record.pressure = pressure
      record.peak = math.max(record.peak or pressure, pressure)
    end
    if finite(raw.slide) then
      local slide = util.clamp(raw.slide, 0, 1)
      if record.reference == nil then record.reference = slide end
      record.slide = slide
    end
    hand_over(voice, slot, record)
    return true
  end

  -- A held note lifted in latch mode (the MIDI package's note off): its
  -- pressure becomes the highest it reached in its touch and its slide
  -- stays where it is; later updates change nothing. false for a note the
  -- allocator does not hold
  function M.latch(voice, owner, key)
    if not valid_voice(voice) then return false end
    local slot = S.lib.notes.find(voice, owner, key)
    if not slot then return false end
    local record = find_record(voice, owner, key) or new_record(voice, owner, key)
    record.latched = true
    record.pressure = record.peak
    hand_over(voice, slot, record)
    return true
  end

  -- A new touch of a note the allocator may still hold (the MIDI package's
  -- note on, before its update): what this module kept of the old touch
  -- (latch, highest pressure, slide reference) is forgotten
  function M.forget(voice, owner, key)
    if not valid_voice(voice) then return end
    local _, index = find_record(voice, owner, key)
    if index then table.remove(records[voice], index) end
  end

  -- The voice-wide values to their homes when they changed (nil or 0:
  -- cleared): cutoff and size as the matrix's fast extras (its next step
  -- sums and sends them), density as an extra offset of the param, sent in
  -- the LFOs' round robin when it moved by their threshold or was set or
  -- cleared
  local density_senders = {}
  for voice = 1, NUM_VOICES do
    local id = param_id(voice, EXPRESSION.wide_params.density)
    density_senders[voice] = function()
      local sync = S.lib.engine_sync
      sync.send_engine_value(id, sync.with_lfo_offsets(id, params:get(id)))
    end
  end

  local function apply_wide(voice, maxima)
    local held = wide_held[voice]
    for _, name in ipairs({"cutoff", "size"}) do
      local m = maxima[name]
      if m == 0 then m = nil end
      if m ~= held[name] then
        held[name] = m
        S.lib.matrix.set_fast_extra(EXPRESSION.extra_key, param_id(voice, EXPRESSION.wide_params[name]), m)
      end
    end
    local id = param_id(voice, EXPRESSION.wide_params.density)
    local offset
    if maxima.density ~= nil and maxima.density ~= 0 then offset = S.lib.lfos.offset_for(id, maxima.density) end
    if offset == held.density then return end
    held.density = offset
    S.lib.engine_sync.set_extra_offset(EXPRESSION.extra_key, id, offset)
    local min, max = param_range(id)
    local marked = held.marked_density
    if offset == nil or marked == nil or math.abs(offset - marked) >= S.lib.lfos.LFO.send_threshold * (max - min) then
      held.marked_density = offset
      S.lib.lfos.mark_due(id, density_senders[voice])
    end
  end

  local function holds_wide(held) return held.cutoff ~= nil or held.size ~= nil or held.density ~= nil end

  -- The step (after the LFOs and the matrix, before the allocator's flush):
  -- per voice, the notes the allocator no longer holds are forgotten; each
  -- held note's values go again when a mapping, the source or the freeze
  -- changed them; each voice-wide target takes the value furthest from 0
  -- among the voice's held notes (the strongest finger, Question 3; the
  -- first of a tie), cleared when none holds one
  local function step()
    for voice = 1, NUM_VOICES do
      local list = records[voice]
      if #list > 0 or holds_wide(wide_held[voice]) then
        local kept, maxima = {}, {}
        for _, record in ipairs(list) do
          local slot = S.lib.notes.find(voice, record.owner, record.key)
          if slot then
            table.insert(kept, record)
            for name, m in pairs(hand_over(voice, slot, record)) do
              if maxima[name] == nil or math.abs(m) > math.abs(maxima[name]) then maxima[name] = m end
            end
          end
        end
        records[voice] = kept
        apply_wide(voice, maxima)
      end
    end
  end
  S.lib.lfos.on_step(step)

  ---------------------------------------------------------------------------
  -- The sources (design §6.5, Question 11)
  ---------------------------------------------------------------------------

  -- The largest of a field (pressure, or the absolute slide) among the
  -- held notes of voices first..last, 0 with none
  local function largest(field, first, last)
    local best = 0
    for voice = first, last do
      for _, record in ipairs(records[voice]) do
        local value = record[field]
        if value ~= nil and value > best and S.lib.notes.find(voice, record.owner, record.key) then best = value end
      end
    end
    return best
  end

  -- Whether voice holds a note that has sent pressure or slide
  local function expressive(voice)
    for _, record in ipairs(records[voice]) do
      if (record.pressure ~= nil or record.slide ~= nil) and S.lib.notes.find(voice, record.owner, record.key) then
        return true
      end
    end
    return false
  end

  local function percent_of(value_fn)
    return function() return string.format("%d%%", math.floor(value_fn() * 100 + 0.5)) end
  end

  local function register_source(key, name, field, first, last, visible)
    local function value() return largest(field, first, last) end
    S.register_mod_source({key = key, name = name, section = EXPRESSION.sources.section, range = {0, 1},
      value = value, describe = percent_of(value), visible = visible})
  end

  register_source("pressure", EXPRESSION.sources.pressure, "pressure", 1, NUM_VOICES)
  register_source("slide", EXPRESSION.sources.slide, "slide", 1, NUM_VOICES)
  for _, kind in ipairs({{field = "pressure", name = EXPRESSION.sources.voice_pressure},
      {field = "slide", name = EXPRESSION.sources.voice_slide}}) do
    for voice = 1, NUM_VOICES do
      register_source(kind.field .. voice, kind.name .. voice, kind.field, voice, voice,
        function() return expressive(voice) end)
    end
  end

  ---------------------------------------------------------------------------
  -- The params (design §6.1): a registered voice-params record
  ---------------------------------------------------------------------------

  -- A depth's text: signed whole percent, as the matrix's depths
  local function depth_text(param)
    local value = param:get()
    return string.format(value > 0 and "+%.0f%%" or "%.0f%%", value)
  end

  -- position is a choice for a buffer voice only: a turn of another
  -- voice's target steps over it, on in the turn's direction (a set, a
  -- scene's or a PSET's, keeps it, and it acts as off there)
  local function step_over_position(voice, value, previous, turned)
    if not turned or value ~= target_index.position or voice_uses_buffer(voice) then return value end
    local direction = (previous ~= nil and previous > value) and -1 or 1
    local stepped = value + direction
    if stepped < 1 or stepped > #EXPRESSION.targets then stepped = value - direction end
    return stepped
  end

  -- VOICE's randomize (ALT+K2 on the notes section): a target the voice
  -- offers, never off, and a whole depth across the range
  local function draw_target(voice)
    local choices = {}
    for index, name in ipairs(EXPRESSION.targets) do
      if name ~= "off" and (name ~= "position" or voice_uses_buffer(voice)) then table.insert(choices, index) end
    end
    return choices[math.random(#choices)]
  end
  local function draw_depth() return math.random(EXPRESSION.depth_range[1], EXPRESSION.depth_range[2]) end

  -- VOICE's layout tests and page renders: each voice on one kind of
  -- source (synth, buffer, input in turn), its targets at their widest
  -- choices and its depths at -100 %, the cursor on the first and the last
  -- of the four rows
  local layout_sources = {{"synth", S.constants.SOURCE_SYNTH}, {"buffer", S.constants.SOURCE_SYNTH + 1},
    {"input", S.constants.SOURCE_INPUT}}
  local layout_states = {}
  for voice = 1, NUM_VOICES do
    local source = layout_sources[(voice - 1) % #layout_sources + 1]
    for _, cursor_key in ipairs({EXPRESSION.mappings[1].target_key, EXPRESSION.mappings[2].depth_key}) do
      table.insert(layout_states, {
        name = string.format("v%d expression %s %s", voice, source[1], cursor_key),
        setup = function()
          S.selected_voice = voice
          params:set(param_id(voice, "source"), source[2])
          local widest = voice_uses_buffer(voice) and "position" or "density"
          params:set(param_id(voice, "press_target"), target_index[widest])
          params:set(param_id(voice, "slide_target"), target_index.density)
          params:set(param_id(voice, "press_depth"), EXPRESSION.depth_range[1])
          params:set(param_id(voice, "slide_depth"), EXPRESSION.depth_range[1])
          S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id(voice, cursor_key)))
        end,
      })
    end
  end

  local scene_defaults, discrete, scene_ranges, rows, randomize = {}, {}, {}, {}, {}
  for _, mapping in ipairs(EXPRESSION.mappings) do
    scene_defaults[mapping.target_key] = target_index[mapping.target]
    scene_defaults[mapping.depth_key] = mapping.depth
    discrete[mapping.target_key] = {1, #EXPRESSION.targets}
    scene_ranges[mapping.depth_key] = EXPRESSION.depth_range
    table.insert(rows, mapping.target_key)
    table.insert(rows, mapping.depth_key)
    randomize[mapping.target_key] = draw_target
    randomize[mapping.depth_key] = draw_depth
  end

  local record
  record = {
    name = "expression",
    count = #rows,
    add = function(voice)
      for _, mapping in ipairs(EXPRESSION.mappings) do
        S.lib.params_setup.add_voice_extra(voice, record, mapping.target_key, {type = "option",
          name = mapping.name .. " target", options = EXPRESSION.targets, default = target_index[mapping.target]})
        S.lib.params_setup.add_voice_extra(voice, record, mapping.depth_key, {type = "control",
          name = mapping.name .. " depth", formatter = depth_text,
          controlspec = controlspec.new(EXPRESSION.depth_range[1], EXPRESSION.depth_range[2], "lin", 1,
            mapping.depth, "%", 1 / (EXPRESSION.depth_range[2] - EXPRESSION.depth_range[1]))})
      end
    end,
    scene_defaults = scene_defaults,
    discrete = discrete,
    scene_ranges = scene_ranges,
    voice_rows = {section = EXPRESSION.section, rows = rows, before = EXPRESSION.before},
    layout_states = layout_states,
    fader = false,
    randomize = randomize,
  }
  S.register_voice_params(record)
  for _, mapping in ipairs(EXPRESSION.mappings) do S.register_param_filter(mapping.target_key, step_over_position) end

  -- A scene older than format 7 (3.4's) gets the four defaults, so it
  -- recalls the sound it was saved with; only what is missing is filled
  S.register_scene_migration({name = "expression", before_version = EXPRESSION.scene_format, migrate = function(scene)
    local voices = type(scene.data) == "table" and scene.data.voices
    if type(voices) ~= "table" then return end
    for voice = 1, NUM_VOICES do
      local data = voices[voice]
      if type(data) == "table" then
        if data.extras == nil then data.extras = {} end
        if type(data.extras) == "table" then
          for key, default in pairs(scene_defaults) do
            if data.extras[key] == nil then data.extras[key] = default end
          end
        end
      end
    end
  end})

  return M
end

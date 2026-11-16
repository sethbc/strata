-- test/unit/expression_test.lua
-- Expression (lib/expression.lua, S.lib.expression, design §6): the four
-- mapping params per voice, a note's five values from its bend, pressure
-- and slide (note_values), a held note's (update, latch, forget), the
-- voice-wide targets (the largest among the held notes), the sixteen
-- modulation sources, the scene migration and VOICE's rows.
-- Run alone: lua test/run.lua expression

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, show_page = h.load_strata, h.local_value, h.finish_startup, h.show_page

-- Voices 1 (Resonator) and 2 (FM) run after the start
local function started(context)
  finish_startup(context)
  local S = local_value("S")
  assert_true(S.voices[1].active and S.voices[2].active, "voices 1 and 2 run")
  return S
end

-- Set a voice's press_target or slide_target to the option named name
local function set_target(voice, which, name)
  local id = "v" .. voice .. "_" .. which .. "_target"
  for index, option in ipairs(params:lookup_param(id).options) do
    if option == name then
      params:set(id, index)
      return index
    end
  end
  error("no target " .. name)
end

local function target_index(voice, which, name)
  for index, option in ipairs(params:lookup_param("v" .. voice .. "_" .. which .. "_target").options) do
    if option == name then return index end
  end
  error("no target " .. name)
end

-- A MIDI note on voice, key key, through the allocator: the slot it took
local function play(voice, key, pitch, expression)
  return local_value("S").lib.notes.play(voice, { owner = "midi", key = key, pitch = pitch or 60, velocity = 0.5,
    park = true, set_own = function() end, expression = expression })
end

local function update(voice, key, raw) return local_value("S").lib.expression.update(voice, "midi", key, raw) end

-- A note on as the MIDI package plays it: a new touch (forget), the note's
-- first expression from note_values of the controller's bend and pressure
-- at slide 0, then its first update with the same values: the slot it took
local function touch(voice, key, pitch, raw)
  local expression = local_value("S").lib.expression
  expression.forget(voice, "midi", key)
  local slot = play(voice, key, pitch, expression.note_values(voice, { bend = raw.bend, pressure = raw.pressure, slide = 0 }))
  update(voice, key, raw)
  return slot
end

local function lfo_step(context, count)
  for _ = 1, count or 1 do context.clock.advance_until(local_value("S").lfo_clock) end
end

-- The noteExpression messages sent for voice's slot (Lua numbering) since
-- the last clear, each {bend, amp, position, size, main}
local function expressions(context, voice, slot)
  local list = {}
  for _, call in ipairs(context.calls_named("noteExpression")) do
    if call.args[1] == voice - 1 and call.args[2] == slot - 1 then
      table.insert(list, { bend = call.args[3], amp = call.args[4], position = call.args[5], size = call.args[6],
        main = call.args[7] })
    end
  end
  return list
end

local function last_expression(context, voice, slot)
  local list = expressions(context, voice, slot)
  return list[#list]
end

-- The last setFastOffset sent for engine voice and destination, or nil
local function last_fast_offset(context, engine_voice, destination)
  local found
  for _, call in ipairs(context.calls_named("setFastOffset")) do
    if call.args[1] == engine_voice and call.args[3] == destination then found = call.args[4] end
  end
  return found
end

local function source_keys(section)
  local keys = {}
  for _, record in ipairs(local_value("S").lib.mod_sources.list(section)) do table.insert(keys, record.key) end
  return table.concat(keys, ",")
end

test("pressure on amp is a swell above the stored level", function()
  load_strata()
  local expression = local_value("S").lib.expression
  local values = expression.note_values(1, { bend = 2, pressure = 0.5, slide = 0 })
  assert_near(values.amp, 1.5, 1e-9, "the default: amp at 100 %")
  assert_equal(values.bend, 2, "the bend passes through")
  assert_equal(values.position, 0); assert_equal(values.size, 0); assert_equal(values.main, 0)
  assert_near(expression.note_values(1, { bend = 1, pressure = 0, slide = 0 }).amp, 1, 1e-9, "zero pressure: the stored level")
  assert_near(expression.note_values(1, { bend = 1, slide = 0 }).amp, 1, 1e-9, "no pressure yet")
  assert_equal(expression.note_values(1, {}).bend, 1, "no bend: 1")
  params:set("v1_press_depth", -100)
  assert_near(expression.note_values(1, { bend = 1, pressure = 0.5, slide = 0 }).amp, 0.5, 1e-9, "a negative depth")
  for _, voice in ipairs({ 0, 8, 1.5, "1" }) do
    assert_equal(expression.note_values(voice, { pressure = 1 }), nil, "no values for voice " .. tostring(voice))
  end
end)

test("pressure on level is the loudness, and neutral until a pressure arrives", function()
  load_strata()
  local expression = local_value("S").lib.expression
  set_target(1, "press", "level")
  assert_near(expression.note_values(1, { pressure = 0.25 }).amp, 0.25, 1e-9, "the pressure is the level")
  assert_near(expression.note_values(1, { slide = 0 }).amp, 1, 1e-9, "neutral until a pressure arrives")
  params:set("v1_press_depth", 50)
  assert_near(expression.note_values(1, { pressure = 0 }).amp, 0.5, 1e-9, "1 - 0.5 x (1 - 0)")
  params:set("v1_press_depth", -50)
  assert_near(expression.note_values(1, { pressure = 0.5 }).amp, 0.75, 1e-9, "below 0: 1 + depth x value")
end)

-- Ruling 34: slide is relative, 0 at every touch's start, so it cannot be
-- a loudness: on level it acts as on amp, both ways
test("slide on level acts as on amp: a gain of 1 + depth x slide", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  set_target(1, "slide", "level")
  params:set("v1_slide_depth", 100)
  assert_near(expression.note_values(1, { slide = 0 }).amp, 1, 1e-9, "a touch's start is the stored level, never silent")
  assert_near(expression.note_values(1, {}).amp, 1, 1e-9, "no slide: the stored level")
  assert_near(expression.note_values(1, { slide = 0.5 }).amp, 1.5, 1e-9, "up: louder")
  assert_near(expression.note_values(1, { slide = -0.5 }).amp, 0.5, 1e-9, "down: quieter")
  params:set("v1_slide_depth", -50)
  assert_near(expression.note_values(1, { slide = 0.5 }).amp, 0.75, 1e-9, "a negative depth turns it around")
  assert_near(expression.note_values(1, { slide = -0.5 }).amp, 1.25, 1e-9)
  -- a held note's first slide leaves it at the stored level
  params:set("v1_slide_depth", 100)
  play(1, 1, 60)
  context.clear_engine_calls()
  update(1, 1, { slide = 0.3 })
  lfo_step(context)
  assert_equal(#context.calls_named("noteExpression"), 0, "nothing changes at the touch's start")
  update(1, 1, { slide = 0.1 })
  lfo_step(context)
  assert_near(last_expression(context, 1, 1).amp, 0.8, 1e-9, "slid down by 0.2")
end)

test("a note's first update sends nothing its first expression already carried", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  local raw = { bend = 1.5, pressure = 0.5, slide = 0.4 }
  local first = expression.note_values(1, { bend = raw.bend, pressure = raw.pressure, slide = 0 })
  assert_near(first.amp, 1.5, 1e-9, "a first expression that is not neutral")
  play(1, 1, 60)
  context.clear_engine_calls()
  assert_equal(play(1, 2, 64, first), 2, "an extra note")
  assert_equal(#context.calls_named("noteExpression"), 1, "its first expression goes with its start")
  context.clear_engine_calls()
  update(1, 2, raw)
  lfo_step(context)
  assert_equal(#context.calls_named("noteExpression"), 0, "the same values: nothing marked due")
  update(1, 2, { pressure = 0.7 })
  lfo_step(context)
  assert_near(last_expression(context, 1, 2).amp, 1.7, 1e-9, "a change goes")
  assert_equal(last_expression(context, 1, 2).bend, 1.5, "with the note's bend")
end)

-- Ruling 36: a new record is seeded from what the allocator holds for the
-- slot, so a first update sends exactly when it differs from that
test("a note's first update is compared with what the allocator holds, whatever play was given", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  play(1, 1, 60)
  play(1, 2, 64, expression.note_values(1, { slide = 0 }))
  context.clear_engine_calls()
  update(1, 2, { pressure = 0.5 })
  lfo_step(context)
  local sent = last_expression(context, 1, 2)
  assert_true(sent ~= nil, "played with no pressure, a first update with some is marked due")
  assert_near(sent.amp, 1.5, 1e-9)
  play(1, 3, 67, expression.note_values(1, { pressure = 0.5, slide = 0 }))
  context.clear_engine_calls()
  update(1, 3, { bend = 1, slide = 0.3 })
  lfo_step(context)
  sent = last_expression(context, 1, 3)
  assert_true(sent ~= nil, "played at amp 1.5, a first update with no pressure is marked due")
  assert_equal(sent.amp, 1, "back to the stored level")
  -- a latch on a note never updated keeps what the allocator holds: the
  -- module knows no pressure of its touch to keep
  play(1, 4, 69, expression.note_values(1, { pressure = 0.5, slide = 0 }))
  context.clear_engine_calls()
  assert_true(S.lib.expression.latch(1, "midi", 4), "latched")
  lfo_step(context)
  params:set("v1_press_depth", 50)
  lfo_step(context)
  assert_equal(#expressions(context, 1, 4), 0, "nothing sent for it, a mapping's change included")
  assert_near(last_expression(context, 1, 2).amp, 1.25, 1e-9, "while the updated notes follow the change")
  assert_near(S.lib.notes.expression(1, 4).amp, 1.5, 1e-9, "the note keeps its first expression")
  assert_equal(update(1, 4, { pressure = 0.1 }), false, "and changes no more")
  lfo_step(context)
  assert_equal(#expressions(context, 1, 4), 0)
end)

test("slide is measured from the touch's first value", function()
  local context = load_strata()
  started(context)
  play(2, 1, 60)
  context.clear_engine_calls()
  assert_equal(update(2, 1, { bend = 1, slide = 64 / 127 }), true, "a held note")
  lfo_step(context)
  assert_equal(#context.calls_named("noteExpression"), 0, "the first slide is the reference: nothing changes")
  update(2, 1, { bend = 1, slide = 96 / 127 })
  lfo_step(context)
  local sent = last_expression(context, 2, 1)
  assert_true(sent ~= nil, "the slide reaches the note")
  assert_near(sent.main, 0.5 * (32 / 127), 1e-9, "main: the default 50 % of the slide since the touch began")
  assert_equal(sent.amp, 1); assert_equal(sent.bend, 1)
  assert_equal(update(3, 1, { slide = 0.5 }), false, "no note held: nothing kept")
  assert_equal(update(2, 9, { slide = 0.5 }), false)
end)

test("main is the def's control on a synth voice, the position on a buffer voice and the size on an input voice", function()
  load_strata()
  local S = local_value("S")
  local expression = S.lib.expression
  params:set("v1_slide_depth", 100)
  local values = expression.note_values(1, { slide = 0.5 })
  assert_near(values.main, 0.5, 1e-9, "synth: main"); assert_equal(values.position, 0); assert_equal(values.size, 0)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  values = expression.note_values(1, { slide = 0.5 })
  assert_near(values.position, 0.5, 1e-9, "buffer: the position"); assert_equal(values.main, 0); assert_equal(values.size, 0)
  params:set("v1_source", S.constants.SOURCE_INPUT)
  values = expression.note_values(1, { slide = 0.5 })
  assert_near(values.size, 0.5, 1e-9, "input: the size"); assert_equal(values.main, 0); assert_equal(values.position, 0)
end)

test("two mappings on one target multiply their gains and add their offsets", function()
  load_strata()
  local S = local_value("S")
  local expression = S.lib.expression
  set_target(1, "slide", "amp")
  assert_near(expression.note_values(1, { pressure = 0.5, slide = 0.4 }).amp, 1.5 * 1.2, 1e-9, "amp and amp multiply")
  set_target(1, "press", "level")
  params:set("v1_slide_depth", 100)
  assert_near(expression.note_values(1, { pressure = 0.25, slide = 0.5 }).amp, 0.25 * 1.5, 1e-9, "level and amp too")
  set_target(1, "press", "amp"); params:set("v1_press_depth", 100)
  assert_near(expression.note_values(1, { pressure = 1, slide = 1 }).amp, 2, 1e-9, "a gain is at most 2")
  set_target(1, "slide", "level")
  assert_near(expression.note_values(1, { pressure = 1, slide = -1 }).amp, 0, 1e-9, "and at least 0")
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  set_target(1, "press", "size"); set_target(1, "slide", "size"); params:set("v1_slide_depth", 50)
  assert_near(expression.note_values(1, { pressure = 0.5, slide = 0.4 }).size, 0.7, 1e-9, "the offsets add")
  params:set("v1_slide_depth", 100)
  assert_near(expression.note_values(1, { pressure = 1, slide = 0.5 }).size, 1, 1e-9, "an offset is at most 1")
  params:set("v1_press_depth", -100)
  assert_near(expression.note_values(1, { pressure = 1, slide = -0.5 }).size, -1, 1e-9, "and at least -1")
end)

test("a voice-wide target takes the largest value among the held notes", function()
  local context = load_strata()
  local S = started(context)
  set_target(1, "press", "cutoff")
  play(1, 1, 60); play(1, 2, 64)
  context.clear_engine_calls()
  update(1, 1, { pressure = 0.2 }); update(1, 2, { pressure = 0.7 })
  lfo_step(context, 2)  -- the matrix's step reads what this module's step set
  assert_near(S.lib.matrix.offset("v1_filter_freq"), 0.7, 1e-9, "the strongest finger")
  assert_near(last_fast_offset(context, 0, 3), 0.7, 1e-9, "the voice filter's cutoff")
  assert_equal(#context.calls_named("noteExpression"), 0, "nothing per note")
  S.lib.notes.release(1, "midi", 2)
  lfo_step(context, 2)
  assert_near(S.lib.matrix.offset("v1_filter_freq"), 0.2, 1e-9, "the other note's")
  params:set("v1_press_depth", -100)
  update(1, 1, { pressure = 0.2 }); play(1, 3, 67); update(1, 3, { pressure = 0.6 })
  lfo_step(context, 2)
  assert_near(S.lib.matrix.offset("v1_filter_freq"), -0.6, 1e-9, "a negative depth: still the strongest finger")
  S.lib.notes.release(1, "midi", 3); S.lib.notes.release(1, "midi", 1)
  context.clear_engine_calls()
  lfo_step(context, 2)
  assert_equal(S.lib.matrix.offset("v1_filter_freq"), 0, "none held: cleared")
  assert_equal(last_fast_offset(context, 0, 3), 0, "the cutoff back where it is stored")
end)

test("size is voice-wide on a synth voice and per note on a buffer voice", function()
  local context = load_strata()
  local S = started(context)
  set_target(1, "press", "size")
  play(1, 1, 60)
  context.clear_engine_calls()
  update(1, 1, { pressure = 0.5 })
  lfo_step(context, 2)
  assert_near(S.lib.matrix.offset("v1_grain_size"), 0.5, 1e-9, "the voice's grain size")
  assert_equal(#context.calls_named("noteExpression"), 0, "nothing per note")
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  context.clear_engine_calls()
  lfo_step(context, 2)
  assert_equal(S.lib.matrix.offset("v1_grain_size"), 0, "a buffer voice: not the voice's")
  assert_near(last_expression(context, 1, 1).size, 0.5, 1e-9, "the note's own, from the next step")
end)

test("a voice stopped under held notes leaves no voice-wide offset standing", function()
  local context = load_strata()
  local S = started(context)
  set_target(1, "press", "cutoff"); set_target(1, "slide", "density")
  local stored = params:get("v1_grain_density")
  touch(1, 1, 60, { pressure = 0.6, slide = 0.2 }); touch(1, 2, 64, { pressure = 0.3, slide = 0.5 })
  update(1, 2, { slide = 0.9 })
  lfo_step(context, 2)
  assert_near(S.lib.matrix.offset("v1_filter_freq"), 0.6, 1e-9, "the cutoff offset held")
  assert_near(S.lib.engine_sync.with_lfo_offsets("v1_grain_density", stored), stored + 0.5 * 0.4 * 49.5, 1e-9,
    "the density offset held")
  toggle_voice(1)
  assert_true(not S.voices[1].active, "stopped with its keys still down")
  lfo_step(context, 2)
  assert_equal(S.lib.matrix.offset("v1_filter_freq"), 0, "the cutoff offset cleared")
  assert_near(S.lib.engine_sync.with_lfo_offsets("v1_grain_density", stored), stored, 1e-9, "the density offset cleared")
  context.clear_engine_calls()
  toggle_voice(1)
  local sent
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "grainDensity" then sent = call.args[3] end
  end
  assert_near(sent, stored * params:get("master_density"), 1e-9, "the next start plays the stored density")
end)

test("a target changed from cutoff to amp under held notes clears the cutoff and gives the notes their amp", function()
  local context = load_strata()
  local S = started(context)
  set_target(1, "press", "cutoff")
  touch(1, 1, 60, { pressure = 0.4 }); touch(1, 2, 64, { pressure = 0.7 })
  lfo_step(context, 2)
  assert_near(S.lib.matrix.offset("v1_filter_freq"), 0.7, 1e-9, "the cutoff offset held")
  context.clear_engine_calls()
  set_target(1, "press", "amp")
  lfo_step(context, 2)
  assert_equal(S.lib.matrix.offset("v1_filter_freq"), 0, "the cutoff offset cleared")
  assert_equal(last_fast_offset(context, 0, 3), 0, "and the engine's")
  assert_near(last_expression(context, 1, 1).amp, 1.4, 1e-9, "each note its amp")
  assert_near(last_expression(context, 1, 2).amp, 1.7, 1e-9)
end)

test("density is an extra offset in the param's units", function()
  local context = load_strata()
  local S = started(context)
  set_target(1, "press", "density")
  local stored = params:get("v1_grain_density")
  assert_true(stored + 24.75 < 100, "room above the stored density")
  play(1, 1, 60)
  context.clear_engine_calls()
  update(1, 1, { pressure = 0.5 })
  lfo_step(context)
  assert_near(S.lib.engine_sync.with_lfo_offsets("v1_grain_density", stored), stored + 24.75, 1e-9,
    "0.5 x half of 1-100")
  local sent = context.calls_named("setGrainParam")
  assert_equal(sent[#sent].args[2], "grainDensity")
  assert_near(sent[#sent].args[3], (stored + 24.75) * params:get("master_density"), 1e-9, "sent")
  S.lib.notes.release(1, "midi", 1)
  context.clear_engine_calls()
  lfo_step(context)
  assert_near(S.lib.engine_sync.with_lfo_offsets("v1_grain_density", stored), stored, 1e-9, "cleared")
  sent = context.calls_named("setGrainParam")
  assert_near(sent[#sent].args[3], stored * params:get("master_density"), 1e-9, "the stored density again")
end)

test("a frozen synth voice has size per note and no main", function()
  local context = load_strata()
  local S = started(context)
  set_target(1, "press", "size")
  params:set("v1_slide_depth", 100)
  params:set("v1_freeze", 1)
  local values = S.lib.expression.note_values(1, { pressure = 0.5, slide = 0.5 })
  assert_near(values.size, 0.5, 1e-9, "size per note: the notes are streams")
  assert_equal(values.main, 0, "no main: the ring no longer hears the voice synths")
  context.clear_engine_calls()
  touch(1, 1, 60, { pressure = 0.5, slide = 0.2 }); update(1, 1, { slide = 0.7 })
  lfo_step(context, 2)
  assert_equal(S.lib.matrix.offset("v1_grain_size"), 0, "not the voice's")
  local sent = last_expression(context, 1, 1)
  assert_near(sent.size, 0.5, 1e-9); assert_equal(sent.main, 0)
  params:set("v1_freeze", 0)
  context.clear_engine_calls()
  lfo_step(context, 2)
  assert_near(S.lib.matrix.offset("v1_grain_size"), 0.5, 1e-9, "unfrozen: the voice's again")
  sent = last_expression(context, 1, 1)
  assert_equal(sent.size, 0); assert_near(sent.main, 0.5, 1e-9, "and main the def's")
end)

test("a latched note keeps its highest pressure", function()
  local context = load_strata()
  local S = started(context)
  touch(1, 1, 60, { pressure = 0.8, slide = 0.2 }); update(1, 1, { pressure = 0.1 })
  context.clear_engine_calls()
  assert_equal(S.lib.expression.latch(1, "midi", 1), true)
  lfo_step(context)
  assert_near(last_expression(context, 1, 1).amp, 1.8, 1e-9, "the highest pressure of the touch")
  context.clear_engine_calls()
  update(1, 1, { pressure = 0.3, slide = 0.9 })
  lfo_step(context)
  assert_equal(#context.calls_named("noteExpression"), 0, "a latched note changes no more")
  assert_near(S.lib.mod_sources.normalized("pressure"), 0.8, 1e-9, "the source reads it")
  assert_near(S.lib.mod_sources.normalized("slide"), 0.2, 1e-9, "its slide where it was")
  assert_equal(S.lib.expression.latch(1, "midi", 9), false, "no such note")
  -- a new touch of the same key, which the allocator still holds: the
  -- player forgets the old one first, and the new touch's updates act
  context.clear_engine_calls()
  touch(1, 1, 60, { pressure = 0.3, slide = 0.9 })
  assert_near(last_expression(context, 1, 1).amp, 1.3, 1e-9, "the new touch's first expression")
  update(1, 1, { pressure = 0.4, slide = 0.95 })
  lfo_step(context)
  assert_near(last_expression(context, 1, 1).amp, 1.4, 1e-9, "its pressure acts: not latched")
  assert_near(last_expression(context, 1, 1).main, 0.5 * 0.05, 1e-9, "its slide from its own start")
end)

test("a note the allocator no longer holds is forgotten at the next step", function()
  local context = load_strata()
  local S = started(context)
  play(1, 1, 60); play(1, 2, 64)
  update(1, 2, { pressure = 0.9, slide = 0.1 })
  S.lib.notes.release(1, "midi", 2)
  assert_equal(S.lib.mod_sources.normalized("pressure"), 0, "the sources count held notes only")
  lfo_step(context)
  context.clear_engine_calls()
  local slot = play(1, 2, 64)
  update(1, 2, { pressure = 0.2, slide = 0.6 })
  lfo_step(context)
  local sent = last_expression(context, 1, slot)
  assert_true(sent ~= nil, "the first update alone reaches the note")
  assert_near(sent.amp, 1.2, 1e-9, "a fresh touch")
  assert_equal(sent.main, 0, "its first slide its own reference, not the ended note's 0.1")
end)

test("a change of a mapping reaches the held notes at the next step", function()
  local context = load_strata()
  started(context)
  touch(1, 1, 60, { pressure = 0.5 })
  lfo_step(context)
  context.clear_engine_calls()
  params:set("v1_press_depth", 50)
  lfo_step(context)
  assert_near(last_expression(context, 1, 1).amp, 1.25, 1e-9, "the new depth")
  context.clear_engine_calls()
  set_target(1, "press", "off")
  lfo_step(context)
  assert_equal(last_expression(context, 1, 1).amp, 1, "off: neutral")
  context.clear_engine_calls()
  lfo_step(context)
  assert_equal(#context.calls_named("noteExpression"), 0, "nothing more while nothing changes")
end)

test("the sources report the largest pressure and slide, overall and per voice", function()
  local context = load_strata()
  local S = started(context)
  local sources = S.lib.mod_sources
  assert_equal(source_keys("notes"), "pressure,slide", "with no note held, the per-voice ones are hidden")
  local names = {}
  for _, record in ipairs(sources.registered("notes")) do
    table.insert(names, record.name)
    assert_equal(record.range[1], 0); assert_equal(record.range[2], 1)
    assert_equal(record.row, nil, "read-only")
  end
  assert_equal(table.concat(names, ","), "PRES,SLID,PR1,PR2,PR3,PR4,PR5,PR6,PR7,SL1,SL2,SL3,SL4,SL5,SL6,SL7")
  local sections = table.concat(sources.sections(), ",")
  assert_true(sections:find("audio,sequences,envelopes,notes", 1, true) ~= nil,
    "after the input's, the random sequences' and the envelopes' sections: " .. sections)
  assert_equal(sources.normalized("pressure"), 0, "nothing held: 0")
  play(1, 1, 60); play(1, 2, 64)
  assert_equal(source_keys("notes"), "pressure,slide", "no expression sent yet")
  update(1, 1, { pressure = 0.7, slide = 0.3 }); update(1, 2, { pressure = 0.2, slide = 0.9 })
  assert_near(sources.normalized("pressure"), 0.7, 1e-9)
  assert_near(sources.normalized("pressure1"), 0.7, 1e-9)
  assert_equal(sources.normalized("pressure2"), 0)
  assert_near(sources.normalized("slide"), 0.9, 1e-9, "the absolute slide")
  assert_near(sources.normalized("slide1"), 0.9, 1e-9)
  assert_equal(source_keys("notes"), "pressure,slide,pressure1,slide1", "PR1 and SL1 show, PR2 does not")
  play(2, 1, 62); update(2, 1, { pressure = 0.95 })
  assert_near(sources.normalized("pressure"), 0.95, 1e-9, "the largest on any voice")
  assert_near(sources.normalized("pressure1"), 0.7, 1e-9, "each voice its own")
  assert_equal(source_keys("notes"), "pressure,slide,pressure1,pressure2,slide1,slide2")
  S.lib.notes.release(1, "midi", 2); S.lib.notes.release(1, "midi", 1)
  assert_equal(sources.normalized("pressure1"), 0, "released: 0")
  assert_equal(source_keys("notes"), "pressure,slide,pressure2,slide2")
end)

test("the four rows join VOICE's notes section, and position shows for a buffer voice only", function()
  local context = load_strata()
  local S = started(context)
  local expected = "note_cap,press_target,press_depth,slide_target,slide_depth"
  for voice = 1, S.constants.NUM_VOICES do
    local keys = {}
    for _, row in ipairs(voice_page_rows(voice)) do
      if row.section == "notes" and row.selectable ~= false then
        local key = row.param_id:match("^v%d+_(.+)$")
        if key == "note_cap" or key:match("^press_") or key:match("^slide_") then table.insert(keys, key) end
      end
    end
    assert_equal(table.concat(keys, ","), expected, "voice " .. voice .. ": after the note cap, in order")
  end
  assert_equal(params:lookup_param("v1_press_target").name, "press target")
  assert_equal(params:lookup_param("v1_slide_depth").name, "slide depth")
  -- E3 on a synth voice's target skips position; a buffer voice's offers it
  show_page("VOICE")
  local function turn(voice, d)
    S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of("v" .. voice .. "_press_target"))
    enc(3, d)
  end
  local density, position, cutoff = target_index(1, "press", "density"), target_index(1, "press", "position"),
    target_index(1, "press", "cutoff")
  params:set("v1_press_target", density)
  turn(1, 1)
  assert_equal(params:get("v1_press_target"), cutoff, "a synth voice: density, then cutoff")
  turn(1, -1)
  assert_equal(params:get("v1_press_target"), density, "and back")
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  turn(1, 1)
  assert_equal(params:get("v1_press_target"), position, "a buffer voice: position")
  -- another voice set to position acts as off
  params:set("v2_press_target", position)
  local values = S.lib.expression.note_values(2, { pressure = 1 })
  assert_equal(values.amp, 1); assert_equal(values.position, 0); assert_equal(values.size, 0)
  assert_equal(values.main, 0)
  -- the section's randomize draws the four rows, position only for a buffer voice
  local record
  for _, each in ipairs(S.registry.voice_params) do if each.name == "expression" then record = each end end
  local drawn = {}
  for _ = 1, 400 do
    for _, which in ipairs({ "press_target", "slide_target" }) do
      drawn["synth " .. record.randomize[which](2)] = true
      drawn["buffer " .. record.randomize[which](1)] = true
    end
    local depth = record.randomize.press_depth(2)
    assert_true(depth >= -100 and depth <= 100, "a depth in range")
  end
  assert_true(drawn["buffer " .. position] and not drawn["synth " .. position], "position for the buffer voice only")
  assert_true(record.randomize.slide_depth ~= nil, "both depths are drawn")
end)

-- 3.6 (design §0.1): what a note's controllers sent, for the targets
test("raw gives a held note's bend, pressure and slide", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  play(1, 7740, 60)
  assert_equal(expression.raw(1, "midi", 7740), nil, "no update yet: no record")
  update(1, 7740, { bend = 1.5 })
  local raw = expression.raw(1, "midi", 7740)
  assert_equal(raw.bend, 1.5); assert_equal(raw.pressure, nil, "no pressure yet"); assert_equal(raw.slide, nil, "nor slide")
  update(1, 7740, { pressure = 0.4, slide = 0.7 })
  raw = expression.raw(1, "midi", 7740)
  assert_equal(raw.bend, 1.5); assert_equal(raw.pressure, 0.4)
  assert_equal(raw.slide, 0.7, "the slide is absolute, not from its reference")
  raw.bend, raw.pressure = 9, 0
  assert_equal(expression.raw(1, "midi", 7740).bend, 1.5, "a copy")
  assert_equal(expression.raw(1, "midi", 7740).pressure, 0.4, "a copy")
  assert_equal(expression.raw(1, "midi", 7741), nil, "an unknown key")
  assert_equal(expression.raw(2, "midi", 7740), nil, "another voice")
  assert_equal(expression.raw(9, "midi", 7740), nil, "no voice 9")
  expression.forget(1, "midi", 7740)
  assert_equal(expression.raw(1, "midi", 7740), nil, "forgotten")
end)

-- 3.6 (build ruling 8): a played note's first values, readable by the
-- targets from its note on, before the note's first update
test("first_touch's values are raw's until the first update, whose record holds the same", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  context.clear_engine_calls()
  expression.first_touch(1, "midi", 7740, { bend = 1.5, pressure = 0.4, slide = 0.7 })
  assert_equal(#context.engine_calls, 0, "it sends nothing")
  local raw = expression.raw(1, "midi", 7740)
  assert_equal(raw.bend, 1.5); assert_equal(raw.pressure, 0.4); assert_equal(raw.slide, 0.7)
  raw.pressure = 0
  assert_equal(expression.raw(1, "midi", 7740).pressure, 0.4, "a copy")
  assert_equal(expression.raw(1, "midi", 7741), nil, "another key")
  assert_equal(expression.raw(2, "midi", 7740), nil, "another voice")
  play(1, 7740, 60)
  update(1, 7740, { bend = 1.5, pressure = 0.4, slide = 0.7 })
  raw = expression.raw(1, "midi", 7740)
  assert_equal(raw.bend, 1.5); assert_equal(raw.pressure, 0.4); assert_equal(raw.slide, 0.7)
  -- the update took the pending values: once the record goes, nothing is left
  S.lib.notes.release(1, "midi", 7740)
  lfo_step(context, 2)
  assert_equal(expression.raw(1, "midi", 7740), nil, "no pending values after the update")
end)

test("forget, and a note that got no slot, leave nothing pending", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  expression.first_touch(1, "midi", 7740, { bend = 1.2, pressure = 0.3 })
  expression.forget(1, "midi", 7740)
  assert_equal(expression.raw(1, "midi", 7740), nil, "forgotten")
  local real_play = S.lib.notes.play
  S.lib.notes.play = function() return nil end
  midi_note_on(1, 60, 100, 2, { bend = 1.2, pressure = 0.3, slide = 0.1 })
  S.lib.notes.play = real_play
  assert_equal(expression.raw(1, "midi", 2 * 128 + 60), nil, "no slot: nothing pending")
end)

test("first_touch keeps only finite values, clamped as update clamps them", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  expression.first_touch(1, "midi", 1, { bend = 0 / 0, pressure = math.huge, slide = 0.5 })
  local raw = expression.raw(1, "midi", 1)
  assert_equal(raw.bend, 1, "a bend that is not finite is 1")
  assert_equal(raw.pressure, nil, "a pressure that is not finite is not kept")
  assert_equal(raw.slide, 0.5)
  expression.first_touch(1, "midi", 2, { bend = 100, pressure = 1.5, slide = -0.2 })
  raw = expression.raw(1, "midi", 2)
  assert_equal(raw.bend, 16, "the allocator's bend range"); assert_equal(raw.pressure, 1); assert_equal(raw.slide, 0)
  expression.first_touch(1, "midi", 3, { bend = 1, slide = 0 / 0 })
  assert_equal(expression.raw(1, "midi", 3).slide, nil, "a slide that is not finite is not kept")
end)

test("first_touch on a bad voice does nothing", function()
  local context = load_strata()
  local S = started(context)
  local expression = S.lib.expression
  expression.first_touch(9, "midi", 1, { bend = 1.5 })
  expression.first_touch(0, "midi", 1, { bend = 1.5 })
  expression.first_touch(1.5, "midi", 1, { bend = 1.5 })
  assert_equal(expression.raw(9, "midi", 1), nil)
  for voice = 1, S.constants.NUM_VOICES do assert_equal(expression.raw(voice, "midi", 1), nil, "voice " .. voice) end
  expression.first_touch(1, "midi", 1, "not a table")
  assert_equal(expression.raw(1, "midi", 1), nil, "a raw that is not a table: nothing")
end)

-- The MIDI package's note on: the targets read the note's first values from its note on
test("a played note's first values are readable as its note starts", function()
  local context = load_strata()
  local S = started(context)
  local seen
  S.register_note_hook({ name = "probe", started = function(voice, _, note)
    seen = S.lib.expression.raw(voice, note.owner, note.key)
  end })
  params:set("midi_channel_mode", 3)  -- mpe selected
  context.midi.send(1, { type = "channel_pressure", val = 127, ch = 2 })
  context.midi.send(1, { type = "cc", cc = 74, val = 127, ch = 2 })
  context.midi.send(1, { type = "note_on", note = 60, vel = 100, ch = 2 })
  assert_true(seen ~= nil, "raw at the note's start")
  assert_equal(seen.pressure, 1); assert_equal(seen.slide, 1)
end)

end

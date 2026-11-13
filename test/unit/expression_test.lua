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
local function play(voice, key, pitch)
  return local_value("S").lib.notes.play(voice, { owner = "midi", key = key, pitch = pitch or 60, velocity = 0.5,
    park = true, set_own = function() end })
end

local function update(voice, key, raw) return local_value("S").lib.expression.update(voice, "midi", key, raw) end

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
  play(1, 1, 60)
  context.clear_engine_calls()
  update(1, 1, { pressure = 0.5, slide = 0.2 }); update(1, 1, { slide = 0.7 })
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
  play(1, 1, 60)
  update(1, 1, { pressure = 0.8, slide = 0.2 }); update(1, 1, { pressure = 0.1 })
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
  -- player forgets the old one first
  S.lib.expression.forget(1, "midi", 1)
  context.clear_engine_calls()
  update(1, 1, { pressure = 0.3, slide = 0.9 })
  lfo_step(context)
  assert_near(last_expression(context, 1, 1).amp, 1.3, 1e-9, "the new touch's pressure")
  assert_equal(last_expression(context, 1, 1).main, 0, "and its own slide reference")
end)

test("a note the allocator no longer holds is forgotten at the next step", function()
  local context = load_strata()
  local S = started(context)
  play(1, 1, 60); play(1, 2, 64)
  update(1, 2, { pressure = 0.9, slide = 0.1 })
  S.lib.notes.release(1, "midi", 2)
  assert_equal(S.lib.mod_sources.normalized("pressure"), 0, "the sources count held notes only")
  lfo_step(context)
  local slot = play(1, 2, 64)
  context.clear_engine_calls()
  update(1, 2, { pressure = 0.2, slide = 0.6 })
  lfo_step(context)
  local sent = last_expression(context, 1, slot)
  assert_near(sent.amp, 1.2, 1e-9, "a fresh touch")
  assert_equal(sent.main, 0, "with its own slide reference")
end)

test("a change of a mapping reaches the held notes at the next step", function()
  local context = load_strata()
  started(context)
  play(1, 1, 60)
  update(1, 1, { pressure = 0.5 })
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
  assert_true(sections:find("audio,notes", 1, true) ~= nil, "after the input's section: " .. sections)
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

test("a 3.4 scene loads with the four defaults", function()
  local subdir = "expression_format6"
  local context = load_strata({ data_subdir = subdir })
  local S = local_value("S")
  capture_scene(1)
  local scene = h.deep_copy(S.scenes[1])
  local keys = { "press_target", "press_depth", "slide_target", "slide_depth" }
  for voice = 1, S.constants.NUM_VOICES do
    for _, key in ipairs(keys) do scene.data.voices[voice].extras[key] = nil end
  end
  -- the migration alone fills what is missing and keeps what is there
  local migration
  for _, record in ipairs(S.registry.scene_migrations) do
    if record.name == "expression" then migration = record end
  end
  assert_true(migration ~= nil and migration.before_version == 7, "a migration for files older than format 7")
  local partial = h.deep_copy(scene)
  partial.data.voices[3].extras.press_depth = -30
  migration.migrate(partial); migration.migrate(partial)
  assert_equal(partial.data.voices[1].extras.press_target, 2, "amp")
  assert_equal(partial.data.voices[1].extras.press_depth, 100)
  assert_equal(partial.data.voices[1].extras.slide_target, 4, "main")
  assert_equal(partial.data.voices[1].extras.slide_depth, 50)
  assert_equal(partial.data.voices[3].extras.press_depth, -30, "a value there stays")
  os.execute("mkdir -p '" .. context.data_dir .. "strata'")
  assert_true(S.lib.data_files.write(context.data_dir .. "strata/scenes.data", { version = 6, scenes = { scene } }),
    "a format 6 file written")
  load_strata({ data_subdir = subdir })
  S = local_value("S")
  assert_equal(S.scene_file.version, 6, "read as an older format")
  for voice = 1, S.constants.NUM_VOICES do
    local extras = S.scenes[1].data.voices[voice].extras
    assert_equal(extras.press_target, 2); assert_equal(extras.press_depth, 100)
    assert_equal(extras.slide_target, 4); assert_equal(extras.slide_depth, 50)
  end
  params:set("v1_press_depth", -30); set_target(1, "slide", "cutoff")
  recall_scene(1, 0)
  assert_equal(params:get("v1_press_depth"), 100, "the recall plays the defaults")
  assert_equal(params:get("v1_slide_target"), 4)
  assert_true(save_scenes_to_disk(), "saved")
  assert_equal(S.lib.data_files.read(context.data_dir .. "strata/scenes.data").version, 7, "as format 7")
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

end

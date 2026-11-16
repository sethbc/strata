-- test/unit/random_sequences_test.lua
-- The random sequences (lib/random_sequences.lua, S.lib.random_sequences,
-- 3.7 design §8): four sequences of sixteen values each, stepping on a
-- division of the tempo (from the LFO clock's step) or at a voice's hits,
-- drift, the params, the modulation sources and their settings rows, and
-- the storage (the live file, the PSET side file and the scene block)
-- Run alone: lua test/run.lua random_sequences

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function loaded(options)
  local context = load_strata(options); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.random_sequences
end

-- Run the clocks until the LFO clock (the sequences step in its hook) has
-- stepped once
local function lfo_step(context) context.clock.advance_until(local_value("S").lfo_clock) end

-- The clock option's index for a division's name, or "voice <v>"
local function clock_index(S, name)
  local names = S.constants.DIVISIONS.names
  for index, division in ipairs(names) do
    if division == name then return index end
  end
  local voice = tonumber(name:match("^voice (%d)$"))
  assert_true(voice ~= nil, "a clock name: " .. name)
  return #names + voice
end

-- Every value of sequence n set by hand to a distinct number
local function distinct(sequences, n)
  for index = 1, 16 do sequences.set_value(n, index, index / 20 - 0.4) end
end

-- The position after `steps` steps from position p on a loop of length
local function moved(p, steps, length) return (p - 1 + steps) % length + 1 end

local function data_dir_name(context) return context.data_dir:match("([^/]+)/$") end

test("a sequence steps on its division and repeats", function()
  local context, S, sequences = loaded()
  params:set("rseq1_length", 4)
  params:set("rseq1_drift", 0)
  params:set("rseq1_clock", clock_index(S, "1/4"))
  distinct(sequences, 1)
  local values = sequences.values(1)
  clock.set_beat(0.5); lfo_step(context)   -- the first reading on the new clock steps nothing
  local start = sequences.position(1)
  assert_true(start >= 1 and start <= 4, "the position is inside the length: " .. start)
  assert_near(sequences.value(1), values[start], 1e-12, "the value at the position")
  for beat = 1, 8 do
    clock.set_beat(beat + 0.5); lfo_step(context)
    local expected = moved(start, beat, 4)
    assert_equal(sequences.position(1), expected, "beat " .. beat .. "'s step")
    assert_near(sequences.value(1), values[expected], 1e-12, "beat " .. beat .. " plays v" .. expected)
  end
  lfo_step(context)
  assert_equal(sequences.position(1), moved(start, 8, 4), "a step inside the same division steps nothing")
  clock.set_beat(11.5); lfo_step(context)  -- from beat 8.5: three divisions in one step
  assert_equal(sequences.position(1), moved(start, 9, 4), "a beat that jumps divisions steps once")
  -- a slower division: 1 bar
  params:set("rseq1_clock", clock_index(S, "1 bar"))
  clock.set_beat(12.5); lfo_step(context)
  local held = sequences.position(1)
  assert_equal(held, moved(start, 9, 4), "a new clock's first reading steps nothing")
  clock.set_beat(15.5); lfo_step(context)
  assert_equal(sequences.position(1), held, "inside the bar")
  clock.set_beat(16.5); lfo_step(context)
  assert_equal(sequences.position(1), moved(held, 1, 4), "the next bar steps")
end)

test("a sequence clocked by a voice steps at each of its hits and at no other voice's", function()
  local context, S, sequences = loaded()
  params:set("rseq2_clock", clock_index(S, "voice 2"))
  local start = sequences.position(2)
  local sync = S.lib.engine_sync
  for _ = 1, 3 do sync.retrigger(2, 1, "step") end
  assert_equal(sequences.position(2), moved(start, 3, 8), "three hits of voice 2: three steps")
  clock.set_beat(clock.get_beats() + 8); lfo_step(context)
  assert_equal(sequences.position(2), moved(start, 3, 8), "the beat does not step it")
  -- voice 3's hits: none
  sync.retrigger(3, 1, "step")
  toggle_voice(3)
  assert_true(S.voices[3].active, "voice 3 started")
  assert_equal(sequences.position(2), moved(start, 3, 8), "voice 3's hits step nothing")
  -- a three-note chord step on voice 2: one step
  assert_true(S.voices[2].active, "voice 2 runs")
  S.patterns[2][1] = 15
  S.lib.sequencer.set_step_attr(2, 1, "notes", { 0, 4, 7 })
  pattern_clock_start()
  assert_equal(sequences.position(2), moved(start, 4, 8), "a chord step is one step")
  pattern_clock_stop()
  -- the other sequences, on their divisions, ignore the hits
  local other = sequences.position(3)
  sync.retrigger(2, 1, "step")
  assert_equal(sequences.position(3), other, "a division clock ignores hits")
end)

test("drift replaces the value just played with its chance", function()
  local context, S, sequences = loaded()
  params:set("rseq1_clock", clock_index(S, "voice 2"))
  distinct(sequences, 1)
  local before = sequences.values(1)
  local real_random, draws = math.random, 0
  math.random = function(...) draws = draws + 1; return real_random(...) end
  for _ = 1, 64 do S.lib.engine_sync.retrigger(2, 1, "step") end
  math.random = real_random
  assert_equal(draws, 0, "drift 0 never draws")
  local after = sequences.values(1)
  for index = 1, 16 do assert_near(after[index], before[index], 1e-12, "v" .. index .. " kept") end
  -- drift 100: a whole pass changes every value it played, and only those
  params:set("rseq1_drift", 100)
  local start = sequences.position(1)
  for _ = 1, 8 do S.lib.engine_sync.retrigger(2, 1, "step") end
  assert_equal(sequences.position(1), start, "a pass")
  after = sequences.values(1)
  for index = 1, 16 do
    if index <= 8 then
      assert_true(math.abs(after[index] - before[index]) > 1e-12, "v" .. index .. " was played and has changed")
      assert_true(after[index] >= -1 and after[index] <= 1, "a draw is inside -1..1")
    else
      assert_near(after[index], before[index], 1e-12, "v" .. index .. " is past the length and kept")
    end
  end
  -- drift 50: one draw for the chance and one for the value at most a step
  params:set("rseq1_drift", 50)
  draws = 0
  math.random = function(...) draws = draws + 1; return real_random(...) end
  S.lib.engine_sync.retrigger(2, 1, "step")
  math.random = real_random
  assert_true(draws >= 1 and draws <= 2, "one chance and at most one value: " .. draws)
end)

test("new draws all sixteen; a value set by hand stays", function()
  local context, S, sequences = loaded()
  distinct(sequences, 3)
  local before = sequences.values(3)
  params:set("rseq3_new", 1)
  local after = sequences.values(3)
  for index = 1, 16 do
    assert_true(math.abs(after[index] - before[index]) > 1e-12, "v" .. index .. " drawn again")
    assert_true(after[index] >= -1 and after[index] <= 1, "inside -1..1")
  end
  assert_true(sequences.set_value(3, 5, 0.25), "a value set by hand")
  assert_true(sequences.set_value(3, 6, 7), "a value past the range is clamped")
  assert_true(not sequences.set_value(3, 17, 0), "an index past sixteen is refused")
  assert_true(not sequences.set_value(5, 1, 0), "a fifth sequence is refused")
  assert_true(not sequences.set_value(3, 1, 0 / 0), "a value that is not finite is refused")
  params:set("rseq3_clock", clock_index(S, "voice 2"))
  for _ = 1, 40 do S.lib.engine_sync.retrigger(2, 1, "step") end
  local kept = sequences.values(3)
  assert_near(kept[5], 0.25, 1e-12, "the hand's value stays at drift 0")
  assert_near(kept[6], 1, 1e-12, "clamped to 1")
  -- values is a copy
  kept[5] = 0.9
  assert_near(sequences.values(3)[5], 0.25, 1e-12, "values(n) is a copy")
end)

test("a shorter length plays the first values and keeps the rest", function()
  local context, S, sequences = loaded()
  params:set("rseq4_clock", clock_index(S, "voice 2"))
  distinct(sequences, 4)
  local before = sequences.values(4)
  params:set("rseq4_length", 16)
  while sequences.position(4) ~= 12 do S.lib.engine_sync.retrigger(2, 1, "step") end
  params:set("rseq4_length", 3)
  assert_true(sequences.position(4) <= 3, "a position past the new length comes inside it")
  local seen = {}
  for _ = 1, 9 do
    S.lib.engine_sync.retrigger(2, 1, "step")
    seen[sequences.position(4)] = true
    assert_true(sequences.position(4) <= 3, "only the first three play")
  end
  assert_true(seen[1] and seen[2] and seen[3], "all three play")
  local after = sequences.values(4)
  for index = 1, 16 do assert_near(after[index], before[index], 1e-12, "v" .. index .. " kept") end
  params:set("rseq4_length", 1)
  assert_equal(params:get("rseq4_length"), 2, "the length is at least two")
end)

test("the four are modulation sources with their fields", function()
  local context, S, sequences = loaded()
  local sources = S.lib.mod_sources
  for n = 1, 4 do
    local record = sources.get("rseq" .. n)
    assert_true(record ~= nil, "rseq" .. n .. " is a source")
    assert_equal(record.name, "RS" .. n)
    assert_equal(record.section, "sequences")
    assert_equal(record.range[1], -1); assert_equal(record.range[2], 1)
    assert_equal(type(record.fields), "function", "the rows follow the length")
  end
  assert_equal(#sources.list("sequences"), 4, "MOD's sequences section")
  params:set("rseq1_clock", clock_index(S, "1/8"))
  local record = sources.get("rseq1")
  assert_equal(record.describe(), "1/8 " .. sequences.position(1) .. "/8", "the clock and the position")
  params:set("rseq1_clock", clock_index(S, "voice 2"))
  assert_equal(record.describe(), "voice 2 " .. sequences.position(1) .. "/8")
  assert_near(record.value(), sequences.value(1), 1e-12, "the value at the position")
  -- the fields at the default length
  local fields = record.fields()
  local labels = {}
  for _, field in ipairs(fields) do labels[#labels + 1] = field.label end
  assert_equal(table.concat(labels, " "), "length drift clock new v1 v2 v3 v4 v5 v6 v7 v8")
  params:set("rseq1_length", 16)
  assert_equal(#record.fields(), 20, "the rows follow the length")
  params:set("rseq1_length", 8)
  fields = record.fields()
  -- each field edits what it names
  assert_equal(fields[1].value(), "8")
  fields[1].enc(2)
  assert_equal(params:get("rseq1_length"), 10, "length's enc")
  params:set("rseq1_length", 8)
  fields[2].enc(5)
  assert_equal(params:get("rseq1_drift"), 5, "drift's enc")
  assert_equal(fields[2].value(), "5%")
  assert_equal(fields[3].value(), "voice 2")
  fields[3].enc(-1)
  assert_equal(fields[3].value(), "voice 1", "clock's enc")
  local before = sequences.values(1)
  fields[4].press()
  local after = sequences.values(1)
  local changed = 0
  for index = 1, 16 do if after[index] ~= before[index] then changed = changed + 1 end end
  assert_equal(changed, 16, "new's press draws all sixteen")
  sequences.set_value(1, 2, 0.5)
  local v2 = record.fields()[6]
  assert_equal(v2.label, "v2")
  assert_equal(v2.value(), "0.500")
  v2.enc(3)
  assert_near(sequences.values(1)[2], 0.53, 1e-9, "a detent is 0.01")
  v2.fine_enc(-4)
  assert_near(sequences.values(1)[2], 0.526, 1e-9, "a fine detent is 0.001")
  v2.enc(100)
  assert_near(sequences.values(1)[2], 1, 1e-12, "held at 1")
  for _, field in ipairs(record.fields()) do
    assert_true(#field.label >= 1 and #field.label <= 8, "a label of 1 to 8 characters: " .. field.label)
    assert_equal(type(field.value()), "string", field.label .. "'s value is text")
  end
  -- MOD opens the settings
  assert_true(S.lib.pages_mod.open_settings("rseq1"), "MOD opens rseq1's settings")
end)

test("the sequence steps before the matrix reads it in the same step", function()
  local context, S, sequences = loaded()
  params:set("rseq1_length", 2)
  params:set("rseq1_clock", clock_index(S, "1/4"))
  sequences.set_value(1, 1, -0.2); sequences.set_value(1, 2, 0.4)
  params:set("reverb_mix", 0.5)
  assert_true(S.lib.matrix.set_routing(1, "rseq1", "reverb_mix"), "a routing from rseq1")
  params:set("matrix_1_depth", 100)
  clock.set_beat(0.5); lfo_step(context)
  local played = sequences.value(1)
  local function engine_value() return S.lib.engine_sync.with_lfo_offsets("reverb_mix", params:get("reverb_mix")) end
  clock.set_beat(0.9)
  while true do
    lfo_step(context)
    if clock.get_beats() >= 1 then break end
    assert_near(sequences.value(1), played, 1e-12, "before the division passes")
    assert_near(engine_value(), 0.5 + S.lib.lfos.offset_for("reverb_mix", played), 1e-9, "the old value's offset")
  end
  local now = sequences.value(1)
  assert_true(math.abs(now - played) > 0.1, "the sequence stepped")
  assert_near(engine_value(), 0.5 + S.lib.lfos.offset_for("reverb_mix", now), 1e-9,
    "the matrix read the new value in the same step")
  assert_equal(S.matrix[1].source, "rseq1", "a routing names its source by key")
end)

test("the values are saved with a PSET and with a scene, and loaded from both", function()
  local context, S, sequences = loaded()
  for n = 1, 4 do distinct(sequences, n) end
  sequences.set_value(2, 7, -1)
  local saved = {}
  for n = 1, 4 do saved[n] = sequences.values(n) end
  local path = context.data_dir .. "strata-01.pset"
  params:write(path)
  local side = context.data_dir .. "strata-01.sequences.data"
  assert_true(util.file_exists(side), "the PSET's side file")
  for n = 1, 4 do params:set("rseq" .. n .. "_new", 1) end
  params:read(path)
  for n = 1, 4 do
    local values = sequences.values(n)
    for index = 1, 16 do assert_near(values[index], saved[n][index], 1e-9, "PSET: rseq" .. n .. " v" .. index) end
  end
  -- a PSET without its side file: the scene default, sixteen zeros
  os.remove(side)
  params:read(path)
  for index = 1, 16 do assert_equal(sequences.values(1)[index], 0, "no side file: v" .. index .. " is 0") end
  -- the scene block
  for n = 1, 4 do distinct(sequences, n) end
  sequences.set_value(4, 16, 0.75)
  capture_scene(1)
  local block = S.scenes[1].data.sequences
  assert_equal(#block, 4, "the block holds four lists")
  assert_near(block[4][16], 0.75, 1e-12)
  for n = 1, 4 do params:set("rseq" .. n .. "_new", 1) end
  recall_scene(1, 0)
  assert_near(sequences.values(4)[16], 0.75, 1e-12, "a recall loads the block")
  assert_near(sequences.values(1)[1], 1 / 20 - 0.4, 1e-12)
  block[4][16] = 0
  assert_near(sequences.values(4)[16], 0.75, 1e-12, "a recall loads a copy")
  -- the live file, written at cleanup and read at the next start
  sequences.set_value(3, 3, -0.625)
  cleanup()
  assert_true(util.file_exists(context.data_dir .. "strata/sequences.data"), "the live file")
  local _, next_S, next_sequences = loaded({ data_subdir = data_dir_name(context) })
  assert_near(next_sequences.values(3)[3], -0.625, 1e-9, "loaded from the live file")
  assert_near(next_sequences.values(4)[16], 0.75, 1e-9)
end)

test("the first start with no live file draws the values; the params default as the design says", function()
  local context, S, sequences = loaded()
  local nonzero = 0
  for n = 1, 4 do
    for _, value in ipairs(sequences.values(n)) do
      assert_true(value >= -1 and value <= 1, "a draw is inside -1..1")
      if value ~= 0 then nonzero = nonzero + 1 end
    end
    assert_equal(params:get("rseq" .. n .. "_length"), 8)
    assert_equal(params:get("rseq" .. n .. "_drift"), 0)
    assert_equal(params:get("rseq" .. n .. "_clock"), 6)
    assert_equal(params:string("rseq" .. n .. "_clock"), "1/8")
  end
  assert_true(nonzero > 60, "the values are drawn: " .. nonzero)
  local group
  for _, param in ipairs(params.params) do
    if param.id == "strata_rseq" then group = param end
  end
  assert_true(group ~= nil and group.n == 16, "the strata_rseq group holds sixteen params")
  local options = params:lookup_param("rseq1_clock").options
  assert_equal(#options, 19, "twelve divisions and seven voices")
  assert_equal(options[12], "1 bar"); assert_equal(options[13], "voice 1"); assert_equal(options[19], "voice 7")
  assert_equal(sequences.RSEQ.count, 4); assert_equal(sequences.RSEQ.values, 16)
  assert_equal(sequences.RSEQ.length_min, 2)
end)

test("a scene without the block gets sixteen zeros, and a block of the wrong shape refuses the scene", function()
  local context, S, sequences = loaded()
  capture_scene(1)
  local scenes = h.deep_copy(S.scenes)
  scenes[1].data.sequences = nil
  util.make_dir(context.data_dir .. "strata")
  assert_true(S.lib.data_files.write(context.data_dir .. "strata/scenes.data",
    { version = S.constants.SCENE_DATA_VERSION, scenes = scenes }))
  load_scenes_from_disk()
  assert_true(S.scenes[1].populated and validate_scene(S.scenes[1]), "the scene without the block loads")
  recall_scene(1, 0)
  for n = 1, 4 do
    for index, value in ipairs(sequences.values(n)) do assert_equal(value, 0, "rseq" .. n .. " v" .. index) end
  end
  local function refused(block, why)
    local scene = h.deep_copy(S.scenes[1])
    scene.data.sequences = block
    assert_true(not validate_scene(scene), "refused: " .. why)
  end
  local function lists(count, length, value)
    local block = {}
    for n = 1, count do
      block[n] = {}
      for index = 1, length do block[n][index] = value or 0 end
    end
    return block
  end
  assert_true(validate_scene(S.scenes[1]), "four lists of sixteen zeros")
  refused(lists(3, 16), "three lists")
  refused(lists(5, 16), "five lists")
  refused(lists(4, 15), "fifteen values")
  refused(lists(4, 17), "seventeen values")
  refused(lists(4, 16, 1.5), "a value past 1")
  refused(lists(4, 16, 0 / 0), "a value that is not a number")
  refused(lists(4, 16, "0"), "a string")
  refused("none", "not a table")
  local named = lists(4, 16); named[1].x = 0
  refused(named, "a key that is no index")
end)

test("the largest scenes file holds 7474 tables", function()
  -- matrix_test.lua writes that file and counts its tables against the
  -- figure; here, the block's share: the block and its four lists, always
  -- captured whole, five tables a scene, 80 in all, over 3.6's 7394
  local context, S = loaded()
  capture_scene(1)
  local block = S.scenes[1].data.sequences
  local tables = 1
  for _, list in pairs(block) do
    assert_equal(type(list), "table")
    for _, value in pairs(list) do assert_equal(type(value), "number", "a list holds numbers only") end
    tables = tables + 1
  end
  assert_equal(tables, 5, "five tables a scene")
  assert_equal(S.lib.data_files.DATA_FILES.largest_scenes_tables, 7394 + 16 * tables)
  assert_equal(S.lib.data_files.DATA_FILES.largest_scenes_tables, 7474)
end)

end

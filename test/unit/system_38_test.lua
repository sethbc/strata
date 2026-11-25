-- test/unit/system_38_test.lua
-- The regression net of 3.9's first part (its plan's Review Focus 5, package
-- 0a): a fresh Strata (init, the start-up, every voice started and stopped,
-- then a voice started on each other source kind: a buffer slot, the input
-- and another voice's output ring) sends what 3.8.0 sent, call for call
-- (test/fixtures/3.8.0-start-calls.lua, recorded before any package of the
-- plan landed; its header says how). The default sound does not move, so
-- every package keeps this green; the one package that re-based the
-- fixture is the grid sequencer plan's 1a, for its ten gateFloor lines (one
-- a start: "a start sends gateFloor 0 once a start"). Compared as
-- test/unit/system_37_test.lua compares a run with 3.6.0's.
-- Run alone: lua test/run.lua system_38

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

local RUN = {
  seed = 38,  -- the fixture's math.randomseed
  fixture = "/test/fixtures/3.8.0-start-calls.lua",
  -- after the default part, each voice set to another source kind while
  -- stopped, then started and stopped in this order: {voice, kind}
  other_sources = {{3, "buffer 1"}, {4, "input"}, {5, "voice 1"}},
}

-- The differences allowed between the run and the fixture, as entries for
-- h.allowed_call_lines (docs/notes/test-harness/run-and-helpers.md). Empty:
-- a package that moves a start's message changes the sound, which the plan
-- forbids; 1a re-based the fixture's own lines instead of adding entries here
local RUN_CALLS_ALLOWED = {}

-- The source param's value of a kind of RUN.other_sources
local function source_value(C, kind)
  if kind == "buffer 1" then return C.SOURCE_SYNTH + 1 end
  if kind == "input" then return C.SOURCE_INPUT end
  if kind == "voice 1" then return C.SOURCE_VOICE_FIRST end
  error("no source kind " .. kind, 2)
end

-- The run: a fresh Strata's start-up, every voice started and stopped,
-- then each of RUN.other_sources started and stopped; its call lines
function RUN.lines()
  math.randomseed(RUN.seed)
  local context = load_strata(); h.finish_startup(context)
  local S = local_value("S")
  for voice = 1, S.constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_buf_scan"), 0, "voice " .. voice .. "'s scan at 0, as recorded")
  end
  for voice = 1, S.constants.NUM_VOICES do
    if not S.voices[voice].active then toggle_voice(voice) end
  end
  for voice = 1, S.constants.NUM_VOICES do
    if S.voices[voice].active then toggle_voice(voice) end
  end
  for _, pair in ipairs(RUN.other_sources) do
    params:set("v" .. pair[1] .. "_source", source_value(S.constants, pair[2]))
  end
  for _, pair in ipairs(RUN.other_sources) do
    toggle_voice(pair[1])
    assert_true(S.voices[pair[1]].active, "voice " .. pair[1] .. " started on " .. pair[2])
  end
  for _, pair in ipairs(RUN.other_sources) do
    toggle_voice(pair[1])
    assert_true(not S.voices[pair[1]].active, "voice " .. pair[1] .. " stopped")
  end
  local lines = {}
  for _, call in ipairs(context.engine_calls) do lines[#lines + 1] = h.call_line(call) end
  return lines
end

test("a default start sends what 3.8.0 sent", function()
  local lines = RUN.lines()
  local recorded, sent = h.allowed_call_lines(dofile(h.repo_root .. RUN.fixture), lines, RUN_CALLS_ALLOWED,
    "a default start")
  local expected, actual = h.canonical_call_lines(recorded), h.canonical_call_lines(sent)
  for index = 1, math.max(#expected, #actual) do
    if expected[index] ~= actual[index] then
      h.fail("call " .. index .. ": 3.8.0 sent " .. tostring(expected[index]) .. ", this build "
        .. tostring(actual[index]) .. " (the call before: " .. tostring(expected[index - 1]) .. ")")
    end
  end
  assert_equal(#actual, #expected, "as many calls as 3.8.0")
end)

-- The grid sequencer's package 1a (design section 1, The start fixture):
-- each start sends the stage's floor once, 0, where the sorted grain keys
-- put seq_gate_floor (between seq_gate's seqGate and seq_gate_release's
-- gateRelease), so a closed gate is as silent as 3.8.0's
test("a start sends gateFloor 0 once a start", function()
  local lines = RUN.lines()
  local starts, floors = 0, 0
  for index, line in ipairs(lines) do
    local voice = line:match("^voiceOn%((%d+),")
    if voice then
      starts = starts + 1
      local found = 0
      for back = index - 1, 1, -1 do
        if lines[back]:match("^voiceOn%(") then break end
        if lines[back]:match('^setGrainParam%(' .. voice .. ', "gateFloor", ') then
          found = found + 1
          assert_equal(lines[back], 'setGrainParam(' .. voice .. ', "gateFloor", 0)', "start " .. starts .. ": at 0")
          assert_equal(lines[back - 1], 'setGrainParam(' .. voice .. ', "seqGate", 0)', "start " .. starts .. ": after seqGate")
          assert_equal(lines[back + 1], 'setGrainParam(' .. voice .. ', "gateRelease", 0.1)',
            "start " .. starts .. ": before gateRelease")
        end
      end
      assert_equal(found, 1, "start " .. starts .. " (voice " .. voice .. ") sends gateFloor once")
    end
    if line:match('"gateFloor"') then floors = floors + 1 end
  end
  assert_equal(starts, local_value("NUM_VOICES") + #RUN.other_sources, "the run's ten starts")
  assert_equal(floors, starts, "no gateFloor outside a start")
end)

-- The grid sequencer's Review Focus 1 (its plan's package 1a): a scene saved
-- before that work, recalled after it, plays what it played. Two format 10
-- scenes, each recalled over a fresh Strata and then played SCENE.steps
-- steps; every engine call from the recall on is compared, in order, with
-- test/fixtures/3.8.0-scene-calls.lua (its header says how it was recorded):
--   "scene 1": the format 10 fixture's scene 1 as saved
--     (test/fixtures/format-10-files.lua: voice 1 on buffer 1, voice 2 on
--     the ring type, its step 3 at level 9 with prob 40, notes {0, 7} and
--     ratchet 3; every voice in accent; LFO 1 on v2_main);
--   "gated": the same file with voice 2's gate on (seq_gate 2), a plain
--     step 1 at level 15 and step 9 at level 12 with a pitch lock of 1.5,
--     written as the file's own text (SCENE.gated_text).
-- The one difference allowed is the gate's floor, which this plan's 1a adds
-- to the full sync the recall sends each voice whose source or type it
-- changes (voices 1 and 2). Every package keeps both green
local SCENE = {
  seed = 38,  -- math.randomseed, before the load
  fixture = "/test/fixtures/3.8.0-scene-calls.lua",
  slot = 1,
  steps = 32,  -- two passes of the scene's sixteen steps
  settle_seconds = 1,  -- run after the recall, before the patterns start
  draws_seed = 38,  -- the play's draws (SCENE.portable_random)
  tempo = 120, step_beats = 1 / 4,  -- the scene's tempo and every voice's division, 1/16
  allowed = {
    -- gs-1a: the floor in the recall's full syncs (grid sequencer design §1)
    {kind = "drop", match = '^setGrainParam%(%d+, "gateFloor", 0%)$', count = 2,
      why = "gs-1a: the recall's full sync of voices 1 and 2 (source and type changed) sends the gate's floor, 0"},
  },
}

-- MINSTD in place of math.random while the patterns play: the step's prob
-- draws the same numbers under Lua 5.3 and LuaJIT (each product under
-- 2 ^ 53), so one recording serves both. Called as math.random is: () a
-- number in [0, 1), (n) 1 to n, (m, n) m to n
function SCENE.portable_random(seed)
  local state = seed
  return function(m, n)
    state = (state * 48271) % 2147483647
    local unit = (state - 1) / 2147483646
    if m == nil then return unit end
    if n == nil then m, n = 1, m end
    return m + math.floor(unit * (n - m + 1))
  end
end

-- The file's text with table `id`'s block `old` (its whole "{...}") replaced
-- by `new`; raises unless the block is exactly `old`
function SCENE.replace_block(text, id, old, new)
  local head = "-- Table: {" .. id .. "}\n"
  local at = text:find(head, 1, true)
  assert(at, "the scenes file has no table " .. id)
  local from = at + #head
  local found = text:sub(from, from + #old - 1)
  assert(found == old, "table " .. id .. " is not as recorded: " .. found)
  return text:sub(1, from - 1) .. new .. text:sub(from + #old)
end

-- The fixture's scenes file with scene 1's voice 2 gated, a plain step and
-- a locked one. Tables of format-10-files.lua's scenes.data: 54 is voice 2's
-- pattern, 65 its steps, 110 its values; 126 is the file's last table
function SCENE.gated_text(text)
  local function pattern(levels)
    local lines = {}
    for step = 1, #levels do lines[step] = "   " .. levels[step] .. ",\n" end
    return "{\n" .. table.concat(lines) .. "}"
  end
  local levels = {0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  local old_pattern = pattern(levels)
  levels[1], levels[9] = 15, 12
  text = SCENE.replace_block(text, 54, old_pattern, pattern(levels))
  text = SCENE.replace_block(text, 65, "{\n   [3]={108},\n}", "{\n   [3]={108},\n   [9]={127},\n}")
  local values = text:match("%-%- Table: {110}\n(%b{})")
  assert(values and select(2, values:gsub('%["seq_gate"%]=1,', "")) == 1, "voice 2's values hold seq_gate 1 once")
  text = SCENE.replace_block(text, 110, values, (values:gsub('%["seq_gate"%]=1,', '["seq_gate"]=2,')))
  assert(text:sub(-2) == "}\n" or text:sub(-1) == "}", "the file ends its list")
  local last = text:find("}%s*$")
  return text:sub(1, last - 1) .. '-- Table: {127}\n{\n   ["pitch"]=1.5,\n},\n' .. text:sub(last)
end

-- A fresh Strata over the scenes file `text`, scene SCENE.slot recalled and
-- the patterns played SCENE.steps steps: the call lines from the recall on
function SCENE.lines(text)
  math.randomseed(SCENE.seed)
  local subdir = "system38-scene-calls-" .. math.random(1, 1e9)
  local root = h.data_root .. subdir .. "/"
  os.execute("mkdir -p '" .. root .. "strata/'")
  h.write_text(root .. "strata/scenes.data", (text:gsub("@DATA@", root)))
  local context = load_strata({data_subdir = subdir}); h.finish_startup(context)
  local S = local_value("S")
  assert_equal(S.scene_file.problem, nil, "the scenes file loads")
  context.clear_engine_calls()
  recall_scene(SCENE.slot)
  local data = S.scenes[SCENE.slot].data
  for voice = 1, S.constants.NUM_VOICES do
    local values = data.voices[voice].values
    assert_equal(params:get("v" .. voice .. "_seq_gate"), values.seq_gate, "voice " .. voice .. "'s gate as saved")
    assert_equal(params:get("v" .. voice .. "_seq_division"), 3, "voice " .. voice .. " at 1/16")
    assert_equal(S.voices[voice].active, data.voices[voice].active, "voice " .. voice .. " running as saved")
  end
  assert_equal(clock.get_tempo(), SCENE.tempo, "at the scene's tempo")
  context.clock.run_for(SCENE.settle_seconds)
  local real_random = math.random
  math.random = SCENE.portable_random(SCENE.draws_seed)
  local played, play_error = pcall(function()
    pattern_clock_start()
    context.clock.run_for(SCENE.steps * SCENE.step_beats * 60 / SCENE.tempo - 0.01)
    pattern_clock_stop()
  end)
  math.random = real_random
  if not played then error(play_error, 0) end
  local lines = {}
  for _, call in ipairs(context.engine_calls) do lines[#lines + 1] = h.call_line(call) end
  return lines, S
end

-- The scene's lines against its recording, but for SCENE.allowed
function SCENE.compare(name, lines)
  local recorded, sent = h.allowed_call_lines(dofile(h.repo_root .. SCENE.fixture)[name], lines, SCENE.allowed, name)
  local expected, actual = h.canonical_call_lines(recorded), h.canonical_call_lines(sent)
  for index = 1, math.max(#expected, #actual) do
    if expected[index] ~= actual[index] then
      h.fail(name .. ", call " .. index .. ": the scene sent " .. tostring(expected[index]) .. ", this build "
        .. tostring(actual[index]) .. " (the call before: " .. tostring(expected[index - 1]) .. ")")
    end
  end
  assert_equal(#actual, #expected, name .. ": as many calls as the recording")
end

test("a format 10 scene plays the steps it played in 3.8.0", function()
  local files = dofile(h.repo_root .. "/test/fixtures/format-10-files.lua")
  SCENE.compare("scene 1", SCENE.lines(files["scenes.data"]))
end)

test("a format 10 scene with a gated voice, a plain step and a lock plays as it did in 3.8.0", function()
  local files = dofile(h.repo_root .. "/test/fixtures/format-10-files.lua")
  local lines, S = SCENE.lines(SCENE.gated_text(files["scenes.data"]))
  assert_equal(params:get("v2_seq_gate"), 2, "voice 2 gated, as the scene holds it")
  assert_equal(S.patterns[2][1], 15, "its plain step 1 at 15")
  assert_equal(S.lib.sequencer.step_attr(2, 9, "pitch"), 1.5, "its step 9's pitch lock")
  local retriggers = 0
  for _, line in ipairs(lines) do
    if line:match("^retrigger%(1, ") then retriggers = retriggers + 1 end
  end
  assert_true(retriggers > 0, "voice 2 is played")
  SCENE.compare("gated", lines)
end)

end

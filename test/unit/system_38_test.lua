-- test/unit/system_38_test.lua
-- The regression net of 3.9's first part (its plan's Review Focus 5, package
-- 0a): a fresh Strata (init, the start-up, every voice started and stopped,
-- then a voice started on each other source kind: a buffer slot, the input
-- and another voice's output ring) sends what 3.8.0 sent, call for call
-- (test/fixtures/3.8.0-start-calls.lua, recorded before any package of the
-- plan landed; its header says how). The default sound does not move, so
-- every package keeps this green; the one package that may re-base the
-- fixture is 4c (#925), for the lines its report names. Compared as
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
-- forbids; 4c re-bases the fixture's own lines instead of adding entries here
local RUN_CALLS_ALLOWED = {}

-- The source param's value of a kind of RUN.other_sources
local function source_value(C, kind)
  if kind == "buffer 1" then return C.SOURCE_SYNTH + 1 end
  if kind == "input" then return C.SOURCE_INPUT end
  if kind == "voice 1" then return C.SOURCE_VOICE_FIRST end
  error("no source kind " .. kind, 2)
end

test("a default start sends what 3.8.0 sent", function()
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

-- The grid sequencer's Review Focus 1 (its plan's package 1a): a scene saved
-- before that work, recalled after it, plays what it played. The format 10
-- fixture's scene 1 (test/fixtures/format-10-files.lua: voice 2 on the ring
-- type, its step 3 at level 9 with prob 40, notes {0, 7} and ratchet 3; LFO
-- 1 on v2_main) is recalled, then the patterns play SCENE.steps steps, and
-- every engine call of the play is compared, in order, with
-- test/fixtures/3.8.0-scene-calls.lua (its header says how it was recorded).
-- The recall's own calls are outside the window: they are a full sync of
-- each voice whose source or type changes, which a new grain key changes,
-- while the steps are what this net pins. Every package keeps it green, with
-- no allowed difference
local SCENE = {
  seed = 38,  -- math.randomseed, before the load
  fixture = "/test/fixtures/3.8.0-scene-calls.lua",
  slot = 1,
  steps = 32,  -- two passes of the scene's sixteen steps
  settle_seconds = 1,  -- run after the recall, before the window opens
  draws_seed = 38,  -- the play's draws (scene.portable_random)
  tempo = 120, step_beats = 1 / 4,  -- the scene's tempo and every voice's division, 1/16
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

test("a format 10 scene plays the steps it played in 3.8.0", function()
  math.randomseed(SCENE.seed)
  local files = dofile(h.repo_root .. "/test/fixtures/format-10-files.lua")
  local subdir = "system38-scene-calls-" .. math.random(1, 1e9)
  local root = h.data_root .. subdir .. "/"
  os.execute("mkdir -p '" .. root .. "strata/'")
  h.write_text(root .. "strata/scenes.data", (files["scenes.data"]:gsub("@DATA@", root)))
  local context = load_strata({data_subdir = subdir}); h.finish_startup(context)
  local S = local_value("S")
  assert_equal(S.scene_file.problem, nil, "the scenes file loads")
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
  context.clear_engine_calls()
  local real_random = math.random
  math.random = SCENE.portable_random(SCENE.draws_seed)
  local played, play_error = pcall(function()
    pattern_clock_start()
    context.clock.run_for(SCENE.steps * SCENE.step_beats * 60 / SCENE.tempo - 0.01)
    pattern_clock_stop()
  end)
  math.random = real_random
  if not played then error(play_error, 0) end
  local sent = {}
  for _, call in ipairs(context.engine_calls) do sent[#sent + 1] = h.call_line(call) end
  local expected, actual = h.canonical_call_lines(dofile(h.repo_root .. SCENE.fixture)), h.canonical_call_lines(sent)
  for index = 1, math.max(#expected, #actual) do
    if expected[index] ~= actual[index] then
      h.fail("call " .. index .. ": the scene sent " .. tostring(expected[index]) .. ", this build "
        .. tostring(actual[index]) .. " (the call before: " .. tostring(expected[index - 1]) .. ")")
    end
  end
  assert_equal(#actual, #expected, "as many calls as the recording")
end)

end

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

end

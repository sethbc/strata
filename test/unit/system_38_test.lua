-- test/unit/system_38_test.lua
-- The regression net of 3.9's first part (its plan's Review Focus 5, package
-- 0a): a fresh Strata (init, the start-up, every voice started and stopped)
-- sends what 3.8.0 sent, call for call (test/fixtures/3.8.0-start-calls.lua,
-- recorded before any package of the plan landed; its header says how). The
-- default sound does not move, so every package keeps this green; the one
-- package that may re-base the fixture is 4c (#925), for the lines its report
-- names. Compared as test/unit/system_37_test.lua compares a run with 3.6.0's.
-- Run alone: lua test/run.lua system_38

return function(h)
local test, assert_equal, load_strata, local_value = h.test, h.assert_equal, h.load_strata, h.local_value

local RUN = {
  seed = 38,  -- the fixture's math.randomseed
  fixture = "/test/fixtures/3.8.0-start-calls.lua",
}

-- The differences allowed between the run and the fixture, as entries for
-- h.allowed_call_lines (docs/notes/test-harness/run-and-helpers.md). Empty:
-- a package that moves a default start's message changes the sound, which
-- the plan forbids; 4c re-bases the fixture's own lines instead of adding
-- entries here
local RUN_CALLS_ALLOWED = {}

-- A call as the fixture writes it: name(args), numbers "%.9g", strings "%q"
local function call_line(call)
  local parts = {}
  for index = 1, #call.args do
    local value = call.args[index]
    parts[index] = type(value) == "number" and string.format("%.9g", value) or string.format("%q", tostring(value))
  end
  return call.name .. "(" .. table.concat(parts, ", ") .. ")"
end

-- Each run of consecutive setVoiceParam lines of one voice sorted (a run's
-- order is a sort's in 3.8.0, a pairs() loop's before); nothing else moves
local function canonical(lines)
  local out, run, run_key = {}, {}, nil
  local function flush()
    table.sort(run)
    for _, line in ipairs(run) do out[#out + 1] = line end
    run, run_key = {}, nil
  end
  for _, line in ipairs(lines) do
    local key = line:match("^(setVoiceParam%(%d+),")
    if key and key == run_key then
      run[#run + 1] = line
    else
      flush()
      if key then run_key, run[1] = key, line else out[#out + 1] = line end
    end
  end
  flush()
  return out
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
  local lines = {}
  for _, call in ipairs(context.engine_calls) do lines[#lines + 1] = call_line(call) end
  local recorded, sent = h.allowed_call_lines(dofile(h.repo_root .. RUN.fixture), lines, RUN_CALLS_ALLOWED,
    "a default start")
  local expected, actual = canonical(recorded), canonical(sent)
  for index = 1, math.max(#expected, #actual) do
    if expected[index] ~= actual[index] then
      h.fail("call " .. index .. ": 3.8.0 sent " .. tostring(expected[index]) .. ", this build "
        .. tostring(actual[index]) .. " (the call before: " .. tostring(expected[index - 1]) .. ")")
    end
  end
  assert_equal(#actual, #expected, "as many calls as 3.8.0")
end)

end

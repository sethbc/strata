-- test/unit/performance_test.lua
-- The performance setting's Lua side (lib/performance.lua): the active file
-- the engine writes (performance_active.data) read into S.performance, the
-- setting file SETUP writes (performance.data), the bufferState stride and
-- the engine stub's tier
-- Run alone: lua test/run.lua performance

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value = h.load_strata, h.local_value

local UNREADABLE = "strata: performance_active.data unreadable, using standard"

local function count_lines(context, text)
  local count = 0
  for _, line in ipairs(context.printed) do
    if line == text then count = count + 1 end
  end
  return count
end

local function write_file(path, text)
  os.execute("mkdir -p '" .. path:match("^(.*)/") .. "'")
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function assert_standard(context, where)
  local S = local_value("S")
  for key, value in pairs(S.constants.STANDARD_PERFORMANCE) do
    assert_equal(S.performance[key], value, where .. ": " .. key)
  end
  assert_equal(params:lookup_param("record_duration").controlspec.maxval, 16, where .. ": record duration")
  assert_equal(count_lines(context, UNREADABLE), 1, where .. ": one console line")
end

test("the active file sets S.performance before any param is added", function()
  h.write_performance_active({tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60,
    reason = "auto: Raspberry Pi 4 Model B Rev 1.4"})
  local context = load_strata()
  local S = local_value("S")
  assert_equal(S.performance.tier, "high")
  assert_equal(S.performance.buffer_seconds, 60)
  assert_equal(S.performance.max_grains, 128)
  assert_equal(S.performance.history_seconds, 60)
  assert_equal(S.performance.reason, "auto: Raspberry Pi 4 Model B Rev 1.4", "the reason, spaces and all")
  assert_equal(params:lookup_param("record_duration").controlspec.maxval, 60)
  assert_equal(count_lines(context, UNREADABLE), 0, "a valid file prints nothing")
  assert_equal(S.registry.params[1].name, "performance", "the first params record")
  -- each tier length the engine may choose
  for _, seconds in ipairs({ 16, 120, 300 }) do
    h.write_performance_active({tier = "high", buffer_seconds = seconds, max_grains = 128, history_seconds = 60})
    load_strata()
    assert_equal(local_value("S").performance.buffer_seconds, seconds, "high, " .. seconds .. " s")
    assert_equal(params:lookup_param("record_duration").controlspec.maxval, seconds)
  end
  h.write_performance_active({tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
    reason = "standard: setting"})
  load_strata()
  assert_equal(local_value("S").performance.tier, "standard", "a standard file")
end)

test("a missing active file gives standard", function()
  local context = load_strata()
  assert_standard(context, "no file")
  assert_true(local_value("S").performance ~= local_value("S").constants.STANDARD_PERFORMANCE,
    "a copy, never the constant itself")
end)

test("an active file with an unknown tier or buffer length gives standard", function()
  local complete = "tier high\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\nreason high: setting\n"
  local cases = {
    { "tier turbo", "tier turbo\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n" },
    { "buffer_seconds 999", "tier high\nbuffer_seconds 999\nmax_grains 128\nhistory_seconds 60\n" },
    { "standard with 60 s", "tier standard\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 16\n" },
    { "truncated", complete:sub(1, 40) },
    { "cut inside a number", "tier high\nbuffer_seconds 12" },
    { "empty", "" },
    { "binary", "\0\1\2tier\0high" },
    { "a fractional length", "tier high\nbuffer_seconds 60.5\nmax_grains 128\nhistory_seconds 60\n" },
    { "a grain count it does not run", "tier high\nbuffer_seconds 60\nmax_grains 256\nhistory_seconds 60\n" },
    { "a history it does not run", "tier high\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 45\n" },
    { "a tier with a trailing word", "tier high please\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n" },
  }
  for _, case in ipairs(cases) do
    h.write_performance_active(case[2])
    local context = load_strata()
    assert_standard(context, case[1])
  end
  -- the complete file, and CRLF line ends, are fine
  for _, text in ipairs({ complete, (complete:gsub("\n", "\r\n")) }) do
    h.write_performance_active(text)
    local context = load_strata()
    assert_equal(local_value("S").performance.tier, "high", "a complete file")
    assert_equal(count_lines(context, UNREADABLE), 0, "no line for a complete file")
  end
end)

-- The engine reads an old active file it cannot remove with the same rules
-- (parseActivePerformance, #153), so it runs what Lua will read: the same
-- texts as test/engine_check/performance.scd
test("parse_active_text reads the texts the engine's parseActivePerformance is checked on alike", function()
  load_strata()
  local parse = local_value("S").lib.performance.parse_active_text
  local valid = parse("tier high\r\nbuffer_seconds 120\r\nmax_grains 128\r\nhistory_seconds 60\r\nreason x y\r\n")
  assert_equal(valid and valid.tier, "high", "CRLF")
  assert_equal(valid.buffer_seconds, 120)
  assert_equal(valid.reason, "x y")
  valid = parse("  tier standard \nbuffer_seconds 16\nmax_grains 128\nhistory_seconds 16\n")
  assert_equal(valid and valid.tier, "standard", "padded, no reason")
  assert_equal(valid.reason, "")
  valid = parse("tier high\nbuffer_seconds 300\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n")
  assert_equal(valid and valid.buffer_seconds, 60, "the last line of a key wins")
  for _, text in ipairs({
    "", "tier high\n", "tier turbo\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 61\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60 s\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60.5\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60\nmax_grains 64\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 16\n",
    "tier standard\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 16\n",
    "tier high please\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n",
  }) do
    assert_equal(parse(text), nil, "refused: " .. text:gsub("\n", "|"))
  end
  assert_equal(parse(nil), nil, "no text")
end)

-- The engine reports its slot length as bufferState's slot index
-- NUM_BUFFERS (8 * 1000 + seconds). An old active file the engine could not
-- replace may name more than memory let it allocate (#153): Lua then caps
-- its slot length to the engine's, so SETUP, BUFFER and the record duration
-- agree with what the slots hold
test("the engine's slot length caps a longer one from the active file", function()
  h.write_performance_active({tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60})
  local context = load_strata(); h.finish_startup(context)
  local S = local_value("S")
  params:set("record_duration", 200)
  local CAPPED = "strata: the engine's slots hold 60 s, not the 300 s performance_active.data names; using 60 s"
  context.polls.fire("bufferState", 8300)    -- the length the file names: nothing changes
  assert_equal(S.performance.buffer_seconds, 300, "an equal length changes nothing")
  context.polls.fire("bufferState", 8060)
  assert_equal(S.performance.buffer_seconds, 60, "capped to the engine's length")
  assert_equal(S.performance.tier, "high", "the tier stays")
  assert_equal(params:lookup_param("record_duration").controlspec.maxval, 60, "the record duration's maximum")
  assert_equal(params:get("record_duration"), 60, "and a longer duration comes down to it")
  assert_equal(count_lines(context, CAPPED), 1, "one console line")
  context.polls.fire("bufferState", 8060)    -- the periodic repeat
  assert_equal(count_lines(context, CAPPED), 1, "said once")
  for _, value in ipairs({ 8000, 8017, 8120, 8600 }) do
    context.polls.fire("bufferState", value) -- no length, not a tier length, or longer: ignored
  end
  assert_equal(S.performance.buffer_seconds, 60, "only a shorter tier length caps it")
  assert_equal(rawget(S.buffers, 9), nil, "no slot 9")
  -- a duration inside the new range is kept as it was
  h.write_performance_active({tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60})
  context = load_strata(); h.finish_startup(context)
  params:set("record_duration", 30)
  context.polls.fire("bufferState", 8060)
  assert_equal(params:get("record_duration"), 30, "a shorter duration is kept")
end)

test("bufferState decodes with stride 1000", function()
  h.write_performance_active({tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60})
  local context = load_strata(); h.finish_startup(context)
  local buffers = local_value("S").buffers
  context.polls.fire("bufferState", 7300)   -- slot 8 holds 300 s
  assert_near(buffers[8].seconds, 300, 1e-9, "slot 8")
  context.polls.fire("bufferState", 2016.5) -- slot 3 holds 16.5 s
  assert_near(buffers[3].seconds, 16.5, 1e-9, "slot 3")
  context.polls.fire("bufferState", 0)
  assert_near(buffers[1].seconds, 0, 1e-9, "slot 1")
  context.polls.fire("bufferState", 8000)   -- slot 9: ignored
  assert_equal(rawget(buffers, 9), nil, "no slot 9")
end)

test("the setting file: missing or garbled values give auto and 60 s", function()
  local cases = {
    { "no file", nil, "auto", 60 },
    { "both garbled", "performance turbo\nbuffer_seconds 999\n", "auto", 60 },
    { "a newer release's values", "performance ultra\nbuffer_seconds 600\nfreeze_tables 4\n", "auto", 60 },
    { "truncated", "performance hi", "auto", 60 },
    { "one key garbled", "performance high\nbuffer_seconds 61\n", "high", 60 },
    { "valid", "performance standard\nbuffer_seconds 300\n", "standard", 300 },
    { "valid, CRLF", "performance high\r\nbuffer_seconds 120\r\n", "high", 120 },
    -- a repeated key keeps its last valid value, as the engine reads it
    { "a later invalid line", "performance high\nperformance turbo\nbuffer_seconds 120\nbuffer_seconds 999\n",
      "high", 120 },
    { "a later valid line", "performance high\nperformance standard\nbuffer_seconds 120\nbuffer_seconds 300\n",
      "standard", 300 },
  }
  for _, case in ipairs(cases) do
    load_strata({ before_init = function(context)
      if case[2] then write_file(context.data_dir .. "strata/performance.data", case[2]) end
    end })
    local setting = local_value("S").lib.performance.setting()
    assert_equal(setting.performance, case[3], case[1] .. ": performance")
    assert_equal(setting.buffer_seconds, case[4], case[1] .. ": buffer_seconds")
  end
end)

test("set_setting writes performance.data through a temporary file and rejects other values", function()
  local context = load_strata()
  local performance = local_value("S").lib.performance
  local path = context.data_dir .. "strata/performance.data"
  assert_true(performance.set_setting("performance", "high"), "high is a choice")
  assert_equal(read_file(path), "performance high\nbuffer_seconds 60\n", "the default length is written too")
  assert_true(performance.set_setting("buffer_seconds", 120))
  assert_equal(read_file(path), "performance high\nbuffer_seconds 120\n")
  assert_equal(read_file(path .. ".part"), nil, "no temporary file left")
  for _, bad in ipairs({ { "performance", "turbo" }, { "buffer_seconds", 999 }, { "buffer_seconds", "60" },
      { "tier", "high" } }) do
    assert_true(not performance.set_setting(bad[1], bad[2]), "rejected: " .. bad[1] .. " " .. tostring(bad[2]))
  end
  assert_equal(read_file(path), "performance high\nbuffer_seconds 120\n", "a rejected value changes nothing")
  -- the next start reads it back
  load_strata({ data_subdir = context.data_dir:match("([^/]+)/$") })
  local setting = local_value("S").lib.performance.setting()
  assert_equal(setting.performance, "high"); assert_equal(setting.buffer_seconds, 120)
end)

test("running_note and step_down_cause read the engine's reason", function()
  local function reason_of(tier, buffer_seconds, history_seconds, reason)
    h.write_performance_active({tier = tier, buffer_seconds = buffer_seconds,
      max_grains = 128, history_seconds = history_seconds, reason = reason})
    load_strata()
    return local_value("S").lib.performance
  end
  local performance = reason_of("standard", 16, 16, "standard: performance_active.data could not be written")
  assert_equal(performance.running_note(), "active file not written")
  performance = reason_of("high", 60, 60, "high: the old performance_active.data (it could not be replaced)")
  assert_equal(performance.running_note(), "old active file kept")
  performance = reason_of("high", 60, 60, "auto: Raspberry Pi 4 Model B Rev 1.4")
  assert_equal(performance.running_note(), nil, "a plain reason has no note")
  assert_equal(performance.step_down_cause(), "memory")
  performance = reason_of("high", 16, 60, "high: setting; buffer 300 s -> 16 s (meminfo unreadable)")
  assert_equal(performance.step_down_cause(), "meminfo")
end)

test("a failed write keeps the old setting and returns false", function()
  local context = load_strata()
  local performance = local_value("S").lib.performance
  local path = context.data_dir .. "strata/performance.data"
  for _, kind in ipairs({ "open", "write", "rename" }) do
    h.with_failing_setting_write(kind, function()
      assert_true(not performance.set_setting("performance", "high"), kind .. ": the save failed")
    end)
    assert_equal(performance.setting().performance, "auto", kind .. ": the old setting stays")
    assert_equal(read_file(path), nil, kind .. ": no performance.data")
    assert_equal(read_file(path .. ".part"), nil, kind .. ": no .part file left")
  end
  assert_true(performance.set_setting("performance", "high"), "the write works again")
  assert_equal(performance.setting().performance, "high")
  assert_equal(read_file(path), "performance high\nbuffer_seconds 60\n")
end)

test("the engine stub's recordBuffer limit follows the active file", function()
  load_strata()
  local ok = pcall(engine.recordBuffer, 0, 16.0, 1.0, 0, 0, 0, 0, 0)
  assert_true(ok, "16 s on standard")
  ok = pcall(engine.recordBuffer, 0, 60.0, 1.0, 0, 0, 0, 0, 0)
  assert_true(not ok, "60 s is more than a standard slot holds")
  h.write_performance_active({tier = "high", buffer_seconds = 120, max_grains = 128, history_seconds = 60})
  local context = load_strata(); h.finish_startup(context)
  assert_true(pcall(engine.recordBuffer, 0, 120.0, 1.0, 0, 0, 0, 0, 0), "120 s on a 120 s high tier")
  assert_true(not pcall(engine.recordBuffer, 0, 121.0, 1.0, 0, 0, 0, 0, 0), "121 s is too long")
  -- a full-length take from the param's range is accepted
  context.clear_engine_calls()
  params:set("record_duration", 120)
  record_buffer(2)
  local calls = context.calls_named("recordBuffer")
  assert_equal(#calls, 1, "one take")
  assert_equal(calls[1].args[2], 120, "the whole 120 s")
  -- a high file Lua rejects (no max_grains or history_seconds) runs standard in the stub too
  h.write_performance_active("tier high\nbuffer_seconds 120\n")
  load_strata()
  assert_equal(local_value("S").performance.tier, "standard", "Lua rejects it")
  assert_true(not pcall(engine.recordBuffer, 0, 60.0, 1.0, 0, 0, 0, 0, 0), "the stub holds 16 s, as Lua")
  assert_true(pcall(engine.recordBuffer, 0, 16.0, 1.0, 0, 0, 0, 0, 0), "16 s is fine")
end)

end

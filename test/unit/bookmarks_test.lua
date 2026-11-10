-- test/unit/bookmarks_test.lua
-- lib/bookmarks.lua: the two functions 3.4's step locks call (design 5.4)
-- Run alone: lua test/run.lua bookmarks

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- Voice 1 (running) on slot 1, holding 8 s; voice 2 (running) on the synth
local function setup()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 8
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("v2_source", 1)
  context.clear_engine_calls()
  return context, S
end

test("S.lib.bookmarks.recall jumps to the bookmark and records it as last recalled", function()
  local context, S = setup()
  S.lib.bookmarks.recall(1, 3)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9)
  assert_equal(S.lib.positions.last_recalled(1), 3)
  local resets = 0
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[1] == 0 and call.args[2] == "t_scanReset" and call.args[3] == 1 then resets = resets + 1 end
  end
  assert_equal(resets, 1, "one scan reset")
end)

test("is_set is false for a synth or input voice, an empty slot, n 0, n 5, n 1.5 and voice 8", function()
  local _, S = setup()
  local bookmarks = S.lib.bookmarks
  for n = 1, 4 do assert_true(bookmarks.is_set(1, n) == true, "voice 1, bookmark " .. n) end
  assert_true(bookmarks.is_set(2, 1) == false, "a synth voice")
  params:set("v2_source", S.constants.SOURCE_INPUT)
  assert_true(bookmarks.is_set(2, 1) == false, "an input voice")
  params:set("v3_source", S.constants.SOURCE_SYNTH + 2)
  assert_true(bookmarks.is_set(3, 1) == false, "an empty slot")
  for _, n in ipairs({0, 5, 1.5, -1, "1"}) do assert_true(bookmarks.is_set(1, n) == false, "n " .. tostring(n)) end
  for _, voice_idx in ipairs({8, 0, 1.5, "1"}) do
    assert_true(bookmarks.is_set(voice_idx, 1) == false, "voice " .. tostring(voice_idx))
  end
  S.buffers[1].seconds = 0
  assert_true(bookmarks.is_set(1, 1) == false, "a slot whose reported seconds are 0")
end)

test("recall does nothing when is_set is false", function()
  local context, S = setup()
  local before = params:get("v1_buf_pos")
  S.lib.bookmarks.recall(1, 5)
  S.lib.bookmarks.recall(2, 1)
  S.lib.bookmarks.recall(1, 1.5)
  S.lib.bookmarks.recall(8, 1)
  assert_equal(params:get("v1_buf_pos"), before, "no param change")
  assert_equal(#context.engine_calls, 0, "no engine call")
end)

test("neither recall nor is_set creates a node", function()
  local context, S = setup()
  local bookmarks = S.lib.bookmarks
  for n = 0, 5 do bookmarks.is_set(1, n); bookmarks.recall(1, n); bookmarks.recall(2, n) end
  assert_equal(#context.calls_named("voiceOn"), 0, "no voiceOn for a running voice")
  assert_equal(#context.calls_named("setGrainSource"), 0, "no setGrainSource")
  toggle_voice(1)  -- stops voice 1
  context.clear_engine_calls()
  bookmarks.recall(1, 2)  -- a stopped voice: still no node
  assert_equal(#context.calls_named("voiceOn"), 0, "no voiceOn")
  assert_equal(#context.calls_named("setGrainSource"), 0, "no setGrainSource")
  assert_equal(#context.calls_named("voiceOff"), 0, "and no stop either")
end)

end

-- test/unit/playheads_test.lua
-- The neutral lib/playheads.lua: its functions answer as pinned and send
-- nothing until its Wave 1 package fills them
-- Run alone: lua test/run.lua playheads

return function(h)
local test, assert_equal, load_strata, local_value = h.test, h.assert_equal, h.load_strata, h.local_value
local finish_startup = h.finish_startup

test("the neutral playheads answers as pinned and sends nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local playheads = S.lib.playheads
  context.clear_engine_calls()
  assert_equal(playheads.position(1), nil)
  assert_equal(playheads.spread(1), nil)
  assert_equal(playheads.record_head(1), nil)
  assert_equal(playheads.column(1, 16), nil)
  playheads.reset(1)
  assert_equal(#context.engine_calls, 0, "no engine call")
end)

end

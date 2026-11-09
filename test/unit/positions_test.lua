-- test/unit/positions_test.lua
-- The neutral lib/positions.lua: its functions answer as pinned and send
-- nothing until its Wave 1 package fills them
-- Run alone: lua test/run.lua positions

return function(h)
local test, assert_equal, load_strata, local_value = h.test, h.assert_equal, h.load_strata, h.local_value
local finish_startup = h.finish_startup

test("the neutral positions answers as pinned and sends nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local positions = S.lib.positions
  context.clear_engine_calls()
  positions.jump(1, 0.5); positions.set_loop(1, 0, 1); positions.recall_bookmark(1, 1); positions.store_bookmark(1, 1)
  positions.hold_scan(1, true); positions.scrub_turned(1); positions.grid_key(1, 1, 1, 16, 1); positions.strip_key(1, 1, 1, 1)
  assert_equal(positions.grid_level(1, 1, 16), 0)
  assert_equal(positions.strip_level(1, 1), 0)
  assert_equal(positions.bookmark(1, 1), nil)
  assert_equal(positions.last_recalled(1), nil)
  assert_equal(#context.engine_calls, 0, "no engine call")
end)

end

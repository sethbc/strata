-- test/unit/bookmarks_test.lua
-- The neutral lib/bookmarks.lua: its functions answer as pinned and send
-- nothing until its Wave 1 package fills them
-- Run alone: lua test/run.lua bookmarks

return function(h)
local test, assert_equal, load_strata, local_value = h.test, h.assert_equal, h.load_strata, h.local_value
local finish_startup = h.finish_startup

test("the neutral bookmarks answers as pinned and sends nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local bookmarks = S.lib.bookmarks
  context.clear_engine_calls()
  bookmarks.recall(1, 1)
  assert_equal(bookmarks.is_set(1, 1), false)
  assert_equal(#context.engine_calls, 0, "no engine call")
end)

end

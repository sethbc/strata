-- test/unit/waveforms_test.lua
-- The neutral lib/waveforms.lua: its functions answer as pinned and send
-- nothing until its Wave 1 package fills them
-- Run alone: lua test/run.lua waveforms

return function(h)
local test, assert_equal, load_strata, local_value = h.test, h.assert_equal, h.load_strata, h.local_value
local finish_startup = h.finish_startup

test("the neutral waveforms answers as pinned and sends nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local waveforms = S.lib.waveforms
  context.clear_engine_calls()
  waveforms.stale(1)
  assert_equal(waveforms.peaks(1), nil)
  assert_equal(waveforms.bins(1, 16), nil)
  assert_equal(#context.engine_calls, 0, "no engine call")
end)

end

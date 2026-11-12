-- test/unit/quantize_test.lua
-- The quantized-action scheduler (lib/quantize.lua, S.lib.quantize): in
-- 3.4's Wave 0 it runs every action at once and adds no param (1f adds
-- quantize_actions and the waits)
-- Run alone: lua test/run.lua quantize

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value = h.load_strata, h.local_value

test("schedule runs its action at once until a quantize param exists", function()
  local context = load_strata()
  local quantize = local_value("S").lib.quantize
  local runs = {}
  assert_equal(quantize.schedule("scene", function() runs[#runs + 1] = "scene" end, "S3"), true, "it ran")
  assert_equal(table.concat(runs, " "), "scene", "at once")
  assert_equal(quantize.waiting("scene"), false, "nothing waits")
  quantize.schedule("scene", function() runs[#runs + 1] = "again" end)
  assert_equal(table.concat(runs, " "), "scene again", "a second action with the same key runs too")
  assert_true(not pcall(quantize.schedule, "scene", nil), "an action is a function")
  assert_true(not pcall(quantize.schedule, nil, function() end), "a key is a string")
  context.clock.run_for(4)
  assert_equal(#runs, 2, "nothing runs later")
end)

test("the scheduler adds no param in Wave 0", function()
  load_strata()
  local quantize = local_value("S").lib.quantize
  assert_equal(quantize.PARAM_COUNT, 0, "no param")
  local before = #params.params
  quantize.add_params()
  assert_equal(#params.params, before, "add_params adds nothing")
end)

end

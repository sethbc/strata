-- test/unit/input_level_test.lua
-- The input level (lib/input_level.lua, S.lib.input_level): norns' two
-- input polls run from the start step to cleanup, and the `input`
-- modulation source (design §10.3)
-- Run alone: lua test/run.lua input_level

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, show_page = h.load_strata, h.local_value, h.finish_startup, h.show_page

test("the source is the louder channel times the gain, clamped", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local level = S.lib.input_level
  assert_equal(level.INPUT_LEVEL.poll_hz, 30)
  assert_near(params:get("input_follow_gain"), 4, 1e-9, "the gain defaults to 4")
  local left, right = level.levels()
  assert_equal(left, 0); assert_equal(right, 0)
  assert_equal(level.value(), 0, "before any poll")
  assert_equal(S.lib.mod_sources.normalized("input"), 0, "no input: no modulation")
  context.polls.fire("amp_in_l", 0.1); context.polls.fire("amp_in_r", 0.05)
  left, right = level.levels()
  assert_near(left, 0.1, 1e-6); assert_near(right, 0.05, 1e-6)
  assert_near(level.value(), 0.4, 1e-6, "0.1 x 4")
  assert_near(S.lib.mod_sources.normalized("input"), level.value(), 1e-9)
  context.polls.fire("amp_in_r", 0.2)
  assert_near(level.value(), 0.8, 1e-6, "the louder channel")
  params:set("input_follow_gain", 30)
  assert_equal(level.value(), 1, "clamped at 1")
  context.polls.fire("amp_in_l", 0 / 0)
  assert_true(level.value() == level.value(), "a NaN poll value never makes a NaN")
end)

test("the polls run from start to cleanup, whatever page shows", function()
  local context = load_strata()
  local left, right = context.polls.polls.amp_in_l, context.polls.polls.amp_in_r
  finish_startup(context)
  assert_true(left.running and right.running, "running after start, on MAIN")
  assert_near(left.time, 1 / 30, 1e-9); assert_near(right.time, 1 / 30, 1e-9)
  for _, page in ipairs({"BUFFER", "SCENES", "MAIN"}) do
    show_page(page)
    assert_true(left.running and right.running, "still running on " .. page)
  end
  cleanup()
  assert_true(not left.running and not right.running, "cleanup stops them")
  assert_equal(left.callback, nil, "and clears their callbacks")
  -- a norns without the polls starts and cleans up quietly
  context = load_strata()
  context.polls.polls.amp_in_l, context.polls.polls.amp_in_r = nil, nil
  finish_startup(context)
  assert_true(pcall(cleanup))
end)

test("on_level runs after each poll", function()
  local context = load_strata(); finish_startup(context)
  local level = local_value("S").lib.input_level
  local calls = 0
  level.on_level(function() calls = calls + 1 end)
  context.polls.fire("amp_in_l", 0.3); context.polls.fire("amp_in_r", 0.1)
  assert_equal(calls, 2, "one per poll value")
  assert_true(not pcall(level.on_level, 5), "a function")
end)

test("the source lists in a section of its own, with its gain on E3", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local sources = S.lib.mod_sources
  local list = sources.list("audio")
  assert_equal(#list, 1); assert_equal(list[1].key, "input"); assert_equal(list[1].name, "IN")
  assert_equal(list[1].range[1], 0); assert_equal(list[1].range[2], 1)
  local found = false
  for _, name in ipairs(sources.sections()) do if name == "audio" then found = true end end
  assert_true(found, "the audio section")
  context.polls.fire("amp_in_l", 0.1)
  assert_equal(list[1].describe(), "40%", "the level in percent")
  local before = params:get("input_follow_gain")
  list[1].row.enc(1)
  local after = params:get("input_follow_gain")
  assert_true(after > before, "E3 raises the gain")
  list[1].row.fine_enc(-1)
  assert_true(params:get("input_follow_gain") < after, "fine lowers it")
  assert_true(params:get("input_follow_gain") > before, "by less than a step")
  assert_equal(type(list[1].row.hints(false)), "string")
end)

test("the group strata_input holds one param", function()
  load_strata()
  assert_equal(params:lookup_param("strata_input").n, 1)
  local spec = params:lookup_param("input_follow_gain").controlspec
  assert_equal(spec.minval, 1); assert_equal(spec.maxval, 30)
end)

test("only lib/input_level.lua names the input polls", function()
  local offenders = {}
  -- (a page's layout state may fire a poll value: that sets nothing)
  local pipe = io.popen("grep -rnE 'amp_in_[lr]' lib 2>/dev/null")
  for line in pipe:lines() do
    local file = line:match("^([^:]+):")
    if file:match("%.lua$") and file ~= "lib/input_level.lua" and not line:find("context.polls.fire", 1, true) then
      offenders[#offenders + 1] = file
    end
  end
  pipe:close()
  assert_equal(table.concat(offenders, " "), "", "a norns poll has one callback")
end)

end

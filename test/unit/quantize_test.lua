-- test/unit/quantize_test.lua
-- The quantized-action scheduler (lib/quantize.lua, S.lib.quantize): the
-- quantize_actions param (off, beat, bar), an action waiting for the next
-- beat or bar, a waiting action replaced by its key's next, the header's
-- flash while it waits, the cleanup that cancels every waiting action, and
-- the strata_seq group the param sits in (alone, or as the sequencer's
-- fifth param)
-- Run alone: lua test/run.lua quantize

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value = h.load_strata, h.local_value

local OFF, BEAT, BAR = 1, 2, 3  -- quantize_actions' options

-- Run the clocks until the beat timeline reads `beat` (120 BPM unless a
-- test sets another tempo)
local function run_to_beat(context, beat)
  context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  assert_near(clock.get_beats(), beat, 1e-6, "the clock reached beat " .. beat)
end

-- An action that counts its runs in runs[name]
local function counter(runs, name)
  return function() runs[name] = (runs[name] or 0) + 1 end
end

test("off runs at once; beat and bar wait for the next one", function()
  local context = load_strata()
  local quantize = local_value("S").lib.quantize
  local runs = {}
  assert_equal(params:get("quantize_actions"), OFF, "off by default")
  assert_equal(quantize.schedule("scene", counter(runs, "now"), "S3"), true, "off: it ran")
  assert_equal(runs.now, 1, "at once")
  assert_equal(quantize.waiting("scene"), false, "nothing waits")

  run_to_beat(context, 1.5)
  params:set("quantize_actions", BAR)
  assert_equal(quantize.schedule("scene", counter(runs, "bar")), false, "bar: it waits")
  params:set("quantize_actions", BEAT)
  assert_equal(quantize.schedule("position2", counter(runs, "beat")), false, "beat: it waits")
  assert_equal(runs.bar, nil, "not before the bar")
  assert_equal(runs.beat, nil, "not before the beat")
  assert_true(quantize.waiting("scene") and quantize.waiting("position2"), "both wait")

  run_to_beat(context, 1.98)
  assert_equal(runs.beat, nil, "beat 1.98: not yet")
  run_to_beat(context, 2.02)
  assert_equal(runs.beat, 1, "beat 2: the beat's action ran")
  assert_equal(quantize.waiting("position2"), false, "and waits no more")
  assert_equal(runs.bar, nil, "the bar's still waits")
  run_to_beat(context, 3.98)
  assert_equal(runs.bar, nil, "beat 3.98: not yet")
  run_to_beat(context, 4.02)
  assert_equal(runs.bar, 1, "beat 4: the bar's action ran, once")
  assert_equal(quantize.waiting("scene"), false)
  run_to_beat(context, 12)
  assert_equal(runs.bar, 1, "it never runs again")
  assert_equal(runs.beat, 1)
  assert_true(not pcall(quantize.schedule, "scene", nil), "an action is a function")
  assert_true(not pcall(quantize.schedule, "", function() end), "a key is a non-empty string")
end)

test("a new action with the same key replaces the waiting one, and cleanup cancels them all", function()
  local context = load_strata()
  local quantize = local_value("S").lib.quantize
  local runs = {}
  run_to_beat(context, 1.5)
  params:set("quantize_actions", BAR)
  quantize.schedule("scene", counter(runs, "first"))
  quantize.schedule("scene", counter(runs, "second"))
  quantize.schedule("freeze3", counter(runs, "freeze"))
  run_to_beat(context, 4.02)
  assert_equal(runs.first, nil, "the replaced action never runs")
  assert_equal(runs.second, 1, "its replacement runs at the bar")
  assert_equal(runs.freeze, 1, "another key's action runs too")

  -- off again: a new action runs at once and the waiting one of its key is dropped
  quantize.schedule("scene", counter(runs, "dropped"))
  params:set("quantize_actions", OFF)
  assert_equal(quantize.schedule("scene", counter(runs, "now")), true)
  assert_equal(runs.now, 1, "off: at once")
  assert_equal(quantize.waiting("scene"), false, "the waiting one is gone")

  params:set("quantize_actions", BEAT)
  quantize.schedule("scene", counter(runs, "canceled"))
  quantize.schedule("bookmark2", counter(runs, "canceled"))
  cleanup()
  assert_equal(quantize.waiting("scene"), false, "cleanup cancels every waiting action")
  assert_equal(quantize.waiting("bookmark2"), false)
  run_to_beat(context, 16)
  assert_equal(runs.dropped, nil, "dropped for good")
  assert_equal(runs.canceled, nil, "the canceled actions never run")
end)

test("schedule names its waiting action, and waiting(key, token) tells whether that one still waits", function()
  local context = load_strata()
  local quantize = local_value("S").lib.quantize
  local ran, none = quantize.schedule("scene", function() end)
  assert_equal(ran, true); assert_equal(none, nil, "an action that ran at once leaves no token")
  params:set("quantize_actions", BAR)
  local waits, first = quantize.schedule("scene", function() end)
  assert_equal(waits, false)
  assert_true(first ~= nil, "a waiting action's token")
  assert_true(quantize.waiting("scene", first), "it waits")
  local _, second = quantize.schedule("scene", function() end)
  assert_true(second ~= first, "each action has its own")
  assert_true(not quantize.waiting("scene", first), "the replaced one waits no more")
  assert_true(quantize.waiting("scene", second) and quantize.waiting("scene"), "its replacement does")
  run_to_beat(context, 4.02)
  assert_true(not quantize.waiting("scene", second), "nor once it ran")
end)

test("a label flashes while it waits", function()
  local context = load_strata()
  local S = local_value("S")
  local quantize = S.lib.quantize
  local runs = {}
  run_to_beat(context, 0.2)
  params:set("quantize_actions", BAR)
  quantize.schedule("scene", counter(runs, "scene"), "S3")
  assert_equal(S.lib.ui_flash.text("header"), "S3 at bar", "the header names the wait")
  run_to_beat(context, 3.9)   -- 1.85 s later, past a usual flash's 1.5 s
  assert_equal(S.lib.ui_flash.text("header"), "S3 at bar", "it shows until the action runs")
  run_to_beat(context, 4.02)
  assert_equal(runs.scene, 1)
  assert_equal(S.lib.ui_flash.text("header"), nil, "and goes when it runs")

  params:set("quantize_actions", BEAT)
  quantize.schedule("freeze1", counter(runs, "freeze"), "v1 freeze")
  assert_equal(S.lib.ui_flash.text("header"), "v1 freeze at beat")
  quantize.schedule("freeze1", counter(runs, "freeze"))
  assert_equal(S.lib.ui_flash.text("header"), nil, "a replacement without a label ends its flash")
  run_to_beat(context, 5.02)
  assert_equal(runs.freeze, 1)
  params:set("quantize_actions", OFF)
  quantize.schedule("scene", counter(runs, "now"), "S4")
  assert_equal(S.lib.ui_flash.text("header"), nil, "an action that runs at once shows nothing")
end)

test("an action that fails at its beat prints a line and leaves nothing waiting", function()
  local context = load_strata()
  local quantize = local_value("S").lib.quantize
  params:set("quantize_actions", BEAT)
  quantize.schedule("scene", function() error("broken action") end)
  run_to_beat(context, 1.02)
  h.claim_script_errors(context, 1, "strata: quantized scene failed: ", "broken action")
  assert_equal(quantize.waiting("scene"), false)
end)

test("every quantized key's flash fits the header, for voice 7 and the longest wait word", function()
  local context = load_strata(); h.finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  params:set("v7_source", S.constants.SOURCE_SYNTH + 1)
  params:set("quantize_actions", BEAT)  -- "beat" is longer than "bar"
  local flashes = {}
  local function flashed() table.insert(flashes, S.lib.ui_flash.text("header")) end
  S.lib.freeze.toggle_quantized(7); flashed()
  S.lib.positions.grid_key(1, 7, 16, 16, 1); S.lib.positions.grid_key(1, 7, 16, 16, 0); flashed()
  S.lib.positions.strip_key(1, 7, 4, 1); S.lib.positions.strip_key(1, 7, 4, 0); flashed()
  assert_equal(table.concat(flashes, "|"), "v7 frz at beat|v7 jump at beat|v7 bm 4 at beat")
  for _, text in ipairs(flashes) do
    assert_true(h.text_width(text) <= S.constants.HEADER.flash_width, text .. " fits the header's flash")
  end
  context.clock.run_for(1)
end)

-- The params of the group starting at index `at`, by id, in menu order
local function group_ids(at)
  local group, ids = params.params[at], {}
  for index = at + 1, at + group.n do table.insert(ids, params.params[index].id) end
  return group, ids
end

local function index_of(id) return params.lookup[id] end

test("quantize_actions is one option, the fifth of the seven params in the sequencer's strata_seq", function()
  load_strata()
  local quantize = local_value("S").lib.quantize
  assert_equal(quantize.PARAM_COUNT, 1, "one param")
  local param = params:lookup_param("quantize_actions")
  assert_equal(param.t, params.tOPTION)
  assert_equal(table.concat(param.options, " "), "off beat bar")
  assert_equal(param.default, OFF)
  local group, ids = group_ids(index_of("strata_seq"))
  assert_equal(group.t, params.tGROUP, "strata_seq is a group")
  assert_equal(table.concat(ids, " "), "seq_chain seq_chain_from seq_chain_scenes seq_chain_bars quantize_actions "
    .. "seq_division_reset seq_follow_transport", "the sequencer's seven, quantize_actions fifth")
end)

test("the sequencer's strata_seq holds quantize_actions as its fifth of seven", function()
  load_strata({ before_init = function()
    local S = local_value("S")
    -- 1d's add_params, as the plan gives it: the group sized 6 +
    -- PARAM_COUNT, quantize's params called for in fifth place
    S.lib.sequencer.add_params = function()
      params:add_group("strata_seq", "sequencer", 6 + S.lib.quantize.PARAM_COUNT)
      for n = 1, 4 do params:add_binary("seq_double_" .. n, "seq double " .. n, "toggle", 0) end
      S.lib.quantize.add_params()
      for n = 5, 6 do params:add_binary("seq_double_" .. n, "seq double " .. n, "toggle", 0) end
    end
  end })
  local group, ids = group_ids(index_of("strata_seq"))
  assert_equal(group.n, 7, "seven params")
  assert_equal(ids[5], "quantize_actions", "quantize_actions is the fifth")
  assert_equal(#ids, 7)
end)

end

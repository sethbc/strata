-- test/unit/grid_pages_fx_test.lua
-- Grid page 7, FX (lib/grid/pages/fx.lua, design §10.9): lines 1-5 the
-- picked set's five faders (delay, reverb, master), line 6 the set keys
-- (x 1-3) and shimmer's interval (x 5-9), line 7 the delay's bypass,
-- sync, freeze and clear (x 1-4), the reverb's bypass and freeze (x 6-7),
-- the filter's three types (x 9-11) and its mix on or off (x 12), on
-- every arrangement (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_fx

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake
local grid_pane = h.grid_pane

-- The page's keys, in pane coordinates (the design's table)
local LINE = {picks = 6, keys = 7}
local FADER_LINES = 5
local SET_X = {delay = 1, reverb = 2, master = 3}
local INTERVAL_FIRST = 5   -- interval i at x 4 + i
local KEY_X = {delay_bypass = 1, delay_sync = 2, delay_freeze = 3, delay_clear = 4, reverb_bypass = 6,
  reverb_freeze = 7, filter_first = 9, filter_mix = 12}

-- Each set's five fader ids, line 1 to 5 (the delay's time line shows
-- the division while synced)
local SETS = {
  {"delay_time", "delay_feedback", "delay_mix", "delay_pingpong", "shimmer_delay"},
  {"reverb_mix", "reverb_size", "reverb_damp", "shimmer_reverb", "delay_to_reverb"},
  {"filter_freq", "filter_res", "filter_mix", "master_density", "drift_amount"},
}

local function shown_columns(pane)
  local first, last
  for x = 1, 16 do
    if pane.shows(x, 1) then
      first = first or x
      last = x
    end
  end
  return first, last
end

local function shown_keys(pane)
  local first, last = shown_columns(pane)
  return last - first + 1
end

-- The pane x of key k (1 the minimum) of a fader line over the shown
-- columns: the 128v's run up (x 1 is its top key)
local function fader_x(pane, k)
  local first, last = shown_columns(pane)
  if pane.arrangement == "128v" then return last - k + 1 end
  return first + k - 1
end

local function fx_pane(context, arrangement, opts)
  local S = local_value("S")
  local pane = grid_pane(context, arrangement, opts)
  pane.show(S.constants.GRID_PAGES.fx, 1, (opts and opts.half) or nil)
  return pane
end

-- Pick a set by its line 6 key; a 64's right half shows none, so there
-- the key is pressed on the left half and the right shown again
local function pick_set(pane, set)
  if pane.shows(set, LINE.picks) then
    pane.tap(set, LINE.picks)
    return
  end
  local S = local_value("S")
  pane.show(S.constants.GRID_PAGES.fx, 1, 1)
  pane.tap(set, LINE.picks)
  pane.show(S.constants.GRID_PAGES.fx, 1, 2)
end

-- Each arrangement (or those that show every key of `needs`, {x, y}
-- pairs) on a fresh load, its pane on the FX page
local function each_arrangement(body, needs)
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = fx_pane(context, arrangement)
    local shown = true
    for _, key in ipairs(needs or {}) do shown = shown and pane.shows(key[1], key[2]) end
    if shown then body(context, S, pane, arrangement) end
  end
end

-- A fader shows its value at 15, a bar of 8 below it and nothing above
local function assert_shown_at(pane, line, k, keys, what)
  assert_equal(pane.led(fader_x(pane, k), line), 15, what .. ": the value at key " .. k)
  if k > 1 then assert_equal(pane.led(fader_x(pane, k - 1), line), 8, what .. ": the bar below it") end
  if k < keys then assert_equal(pane.led(fader_x(pane, k + 1), line), 0, what .. ": nothing above it") end
end

local function pattern_sum(S)
  local sum = 0
  for voice_idx = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do sum = sum + S.patterns[voice_idx][step] end
  end
  return sum
end

-- Every param's value, as one string: a press that changes nothing
-- leaves it as it was
local function param_snapshot()
  local parts = {}
  for _, param in ipairs(params.params) do
    -- (a param the test took out of the lookup is no param; a voice's
    -- params are left out: a drift tick moves a running voice's pitch,
    -- and no key of the page reaches a voice)
    if param.id and params.lookup[param.id] and not param.id:match("^v%d+_") then parts[#parts + 1] = param.id .. "=" .. tostring(params:get(param.id)) end
  end
  return table.concat(parts, " ")
end

-- 3a's seam in the test's own S: a reverb freeze record in FX_HOLD and a
-- binary param of the record's id (the id written once, in the record)
local function plant_reverb_freeze(S)
  S.lib.fx_hold.FX_HOLD.reverb = {freeze_id = "reverb_freeze"}
  params:add{type = "binary", id = S.lib.fx_hold.FX_HOLD.reverb.freeze_id, name = "reverb freeze",
    behavior = "toggle", default = 0}
  assert_true(S.lib.fx_hold.offered("reverb"), "the planted record makes the reverb's freeze offered")
  grid_redraw()
  return S.lib.fx_hold.FX_HOLD.reverb.freeze_id
end

test("the FX page is registered at its index", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.fx]
  assert_true(record ~= nil, "a record at page 7")
  assert_equal(record.name, "fx")
  assert_equal(S.lib.grid_pages_fx.record, record, "the module keeps its record")
  assert_true(record.faders ~= nil and record.signature ~= nil, "fader lines and a signature")
  assert_equal(record.sides, nil, "one side")
end)

-- Moved (0e's hand-on list for 4b): the 256's "grid page 4 shows FX
-- faders in rows 3-7 and keeps row 8/16", in pane coordinates
test("the FX faders show and set", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    local steps = pattern_sum(S)
    -- the delay at first: feedback on line 2, level on line 3
    pane.tap(fader_x(pane, keys), 2)
    assert_near(params:get("delay_feedback"), 0.95, 1e-9, arrangement .. ": the top key: the feedback's top")
    assert_shown_at(pane, 2, keys, keys, arrangement .. ": feedback")
    pane.tap(fader_x(pane, 1), 3)
    assert_equal(params:get("delay_mix"), 0, arrangement .. ": key 1: the level's bottom")
    assert_shown_at(pane, 3, 1, keys, arrangement .. ": level")
    -- the master: the cutoff's top, the resonance's middle
    pick_set(pane, SET_X.master)
    pane.tap(fader_x(pane, keys), 1)
    assert_near(params:get("filter_freq"), 20000, 1, arrangement .. ": the cutoff's top")
    local middle = keys / 2
    pane.tap(fader_x(pane, middle), 2)
    assert_near(params:get("filter_res"), (middle - 1) / (keys - 1), 0.01, arrangement .. ": key " .. middle .. "'s share")
    assert_shown_at(pane, 2, middle, keys, arrangement .. ": resonance")
    assert_equal(pattern_sum(S), steps, arrangement .. ": fader keys toggle no step")
    -- an FX change made elsewhere moves its fader at once
    pick_set(pane, SET_X.delay)
    params:set("delay_mix", 1)
    assert_shown_at(pane, 3, keys, keys, arrangement .. ": the level set elsewhere")
  end)
end)

-- Moved: the 256's "the delay fader picks the division while the delay is
-- synced" (ruling P6: the line holds DELAY.max_seconds)
test("the time fader picks the division while synced", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    local divisions = #S.constants.DIVISIONS.names
    local time = params:get("delay_time")
    pane.tap(KEY_X.delay_sync, LINE.keys)
    assert_equal(params:get("delay_sync"), 1, arrangement .. ": ds syncs the delay")
    assert_equal(pane.led(fader_x(pane, fader_position("delay_division", keys)), 1), 15,
      arrangement .. ": line 1 shows the division")
    pane.tap(fader_x(pane, keys), 1)
    assert_equal(params:get("delay_division"), divisions, arrangement .. ": the last key: the last division")
    assert_shown_at(pane, 1, keys, keys, arrangement .. ": the last division")
    pane.tap(fader_x(pane, 1), 1)
    assert_equal(params:get("delay_division"), 1, arrangement .. ": the first key: the first division")
    assert_shown_at(pane, 1, 1, keys, arrangement .. ": the first division")
    local middle = keys / 2
    pane.tap(fader_x(pane, middle), 1)
    assert_equal(params:get("delay_division"), util.round(1 + (middle - 1) / (keys - 1) * (divisions - 1)),
      arrangement .. ": key " .. middle .. ": its place among the divisions")
    assert_near(params:get("delay_time"), time, 1e-9, arrangement .. ": delay_time is left alone")
    params:set("delay_division", divisions)
    assert_shown_at(pane, 1, keys, keys, arrangement .. ": a division set elsewhere moves the fader")
    pane.tap(KEY_X.delay_sync, LINE.keys)
    assert_equal(params:get("delay_sync"), 0, arrangement .. ": ds again: unsynced")
    assert_equal(pane.led(fader_x(pane, fader_position("delay_time", keys)), 1), 15,
      arrangement .. ": unsynced, the line shows delay_time")
    pane.tap(fader_x(pane, keys), 1)
    assert_near(params:get("delay_time"), S.lib.delay_sync.DELAY.max_seconds, 1e-6,
      arrangement .. ": unsynced, the last key is the line's whole length")
    assert_equal(params:get("delay_division"), divisions, arrangement .. ": the division kept")
  end, {{KEY_X.delay_sync, LINE.keys}})
end)

-- Moved: the 256's "a scene transition redraws the grid once per step on
-- grid page 4"
test("a scene transition redraws once per step", function()
  each_arrangement(function(context, S, pane, arrangement)
    pick_set(pane, SET_X.master)
    local fx = {filter_freq = 1000, filter_res = 0.2, filter_mix = 0.6, delay_time = 0.8, delay_feedback = 0.7,
      delay_mix = 0.5}
    for id, value in pairs(fx) do params:set(id, value) end
    capture_scene(1)
    for id, value in pairs(fx) do params:set(id, value / 2) end
    recall_scene(1, 4)  -- step 1 runs now
    for step = 2, 20 do
      local refreshes = pane.device.refresh_count
      wake(context, "scene_transition_clock")
      assert_equal(pane.device.refresh_count - refreshes, 1, arrangement .. ": one grid redraw at step " .. step)
    end
    wake(context, "scene_transition_clock")  -- the end: the instant recall
    assert_near(params:get("filter_freq"), 1000, 1, arrangement .. ": the transition landed")
    local refreshes = pane.device.refresh_count
    params:set("delay_mix", 0.1)
    assert_equal(pane.device.refresh_count - refreshes, 1, arrangement .. ": outside it an FX edit redraws once")
    assert_true(S.scene_transition_active == false, arrangement .. ": no fade left")
  end)
end)

-- Moved: grid_core_test.lua's "an FX change redraws the grids only while
-- one shows the FX faders" (the gate is any_page(GRID_PAGES.fx))
test("an FX change redraws only while a grid shows the FX page", function()
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = grid_pane(context, arrangement)
    pane.show(S.constants.GRID_PAGES.patterns)
    if arrangement == "256 bottom" then S.lib.grid_core.set_page(1, S.constants.GRID_PAGES.patterns, 1) end
    local before = pane.device.refresh_count
    for _, id in ipairs({"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}) do
      params:delta(id, 1)
    end
    assert_equal(pane.device.refresh_count, before, arrangement .. ": no pane on FX: no redraw")
    pane.show(S.constants.GRID_PAGES.fx)
    before = pane.device.refresh_count
    params:delta("delay_mix", 1)
    assert_equal(pane.device.refresh_count, before + 1, arrangement .. ": a pane on FX: one redraw")
  end
end)

test("each set's five faders", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    for set, ids in ipairs(SETS) do
      pick_set(pane, set)
      for line, id in ipairs(ids) do
        local min, max = param_range(id)
        pane.tap(fader_x(pane, keys), line)
        assert_near(params:get(id), max, 1e-6, arrangement .. ": set " .. set .. " line " .. line .. ": " .. id .. "'s top")
        assert_shown_at(pane, line, keys, keys, arrangement .. ": " .. id)
        pane.tap(fader_x(pane, 1), line)
        assert_near(params:get(id), min, 1e-6, arrangement .. ": " .. id .. "'s bottom")
        assert_shown_at(pane, line, 1, keys, arrangement .. ": " .. id .. " at its bottom")
      end
    end
    assert_equal(#SETS[1], FADER_LINES, "five lines a set")
    -- lines 6 and 7 are no fader lines
    local lines = {}
    for _, line in ipairs(S.lib.grid_pages_fx.record.faders({state = function() return {} end})) do
      lines[#lines + 1] = line.line
    end
    assert_equal(table.concat(lines, " "), "1 2 3 4 5", arrangement .. ": the fader lines")
  end)
end)

test("the interval keys", function()
  each_arrangement(function(_, S, pane, arrangement)
    local SHIMMER = S.lib.shimmer.SHIMMER
    local count = #SHIMMER.ratios
    local first, last = shown_columns(pane)
    for interval = 1, count do
      local x = INTERVAL_FIRST + interval - 1
      if pane.shows(x, LINE.picks) then
        pane.tap(x, LINE.picks)
        assert_equal(params:get(SHIMMER.interval_id), interval, arrangement .. ": key " .. x .. " picks interval " .. interval)
        for other = 1, count do
          local ox = INTERVAL_FIRST + other - 1
          if pane.shows(ox, LINE.picks) then
            assert_equal(pane.led(ox, LINE.picks), other == interval and 15 or 4, arrangement .. ": interval key " .. ox)
          end
        end
      end
    end
    -- set elsewhere (FX, a scene), it shows within a drift tick (after a
    -- first look: the load's first tick always repaints)
    drift_update()
    params:set(SHIMMER.interval_id, SHIMMER.default_interval)
    drift_update()
    for x = first, last do
      local interval = x - INTERVAL_FIRST + 1
      if interval >= 1 and interval <= count then
        assert_equal(pane.led(x, LINE.picks), interval == SHIMMER.default_interval and 15 or 4, arrangement .. ": after a tick, key " .. x)
      elseif x > #SETS then
        assert_equal(pane.led(x, LINE.picks), 0, arrangement .. ": line 6 key " .. x .. " dark")
      end
    end
  end)
end)

test("line 7's keys and levels", function()
  each_arrangement(function(context, S, pane, arrangement)
    local function key(name) return KEY_X[name], LINE.keys end
    local function shows(name) return pane.shows(key(name)) end
    -- the bypasses: 8 playing, 2 bypassed
    for _, name in ipairs({"delay_bypass", "reverb_bypass"}) do
      if shows(name) then
        assert_equal(pane.led(key(name)), 8, arrangement .. ": " .. name .. " playing: 8")
        pane.tap(key(name))
        assert_equal(params:get(name), 1, arrangement .. ": " .. name .. " pressed: bypassed")
        assert_equal(pane.led(key(name)), 2, arrangement .. ": bypassed: 2")
        pane.tap(key(name))
        assert_equal(params:get(name), 0, arrangement .. ": pressed again: playing")
        assert_equal(pane.led(key(name)), 8, arrangement .. ": 8")
      end
    end
    -- sync and the delay's freeze: 15 on, 4 off
    for _, name in ipairs({"delay_sync", "delay_freeze"}) do
      if shows(name) then
        assert_equal(pane.led(key(name)), 4, arrangement .. ": " .. name .. " off: 4")
        pane.tap(key(name))
        assert_equal(params:get(name), 1, arrangement .. ": " .. name .. " on")
        assert_equal(pane.led(key(name)), 15, arrangement .. ": 15")
        pane.tap(key(name))
        assert_equal(params:get(name), 0, arrangement .. ": " .. name .. " off again")
        assert_equal(pane.led(key(name)), 4, arrangement .. ": 4")
      end
    end
    -- clear: the trigger at the press, 15 while held
    if shows("delay_clear") then
      context.clear_engine_calls()
      pane.press(KEY_X.delay_clear, LINE.keys, 1)
      assert_equal(#context.calls_named("clearDelay"), 1, arrangement .. ": DC clears the delay at its press")
      assert_equal(pane.led(key("delay_clear")), 15, arrangement .. ": 15 while held")
      pane.press(KEY_X.delay_clear, LINE.keys, 0)
      assert_equal(#context.calls_named("clearDelay"), 1, arrangement .. ": the release clears nothing")
      assert_equal(pane.led(key("delay_clear")), 4, arrangement .. ": 4 let go")
    end
    -- the filter's types and its mix
    for type_index = 1, 3 do
      local x = KEY_X.filter_first + type_index - 1
      if pane.shows(x, LINE.keys) then
        pane.tap(x, LINE.keys)
        assert_equal(params:get("filter_type"), type_index, arrangement .. ": key " .. x .. " sets the type")
        for other = 1, 3 do
          assert_equal(pane.led(KEY_X.filter_first + other - 1, LINE.keys), other == type_index and 15 or 4,
            arrangement .. ": type key " .. other)
        end
      end
    end
    if shows("filter_mix") then
      assert_equal(pane.led(key("filter_mix")), 4, arrangement .. ": fm at mix 0: 4")
      pane.tap(key("filter_mix"))
      assert_equal(params:get("filter_mix"), S.fx_last_mix.filter, arrangement .. ": fm brings the restore mix back")
      assert_equal(pane.led(key("filter_mix")), 15, arrangement .. ": mix above 0: 15")
      pane.tap(key("filter_mix"))
      assert_equal(params:get("filter_mix"), 0, arrangement .. ": fm again: 0")
      assert_equal(pane.led(key("filter_mix")), 4, arrangement .. ": 4")
    end
    -- the rest of lines 6 and 7: dark and dead
    local first, last = shown_columns(pane)
    local dead = {[LINE.picks] = {4, 10, 11, 12, 13, 14, 15, 16}, [LINE.keys] = {5, 8, 13, 14, 15, 16}}
    for line, xs in pairs(dead) do
      for _, x in ipairs(xs) do
        if x >= first and x <= last then
          assert_equal(pane.led(x, line), 0, arrangement .. ": line " .. line .. " key " .. x .. " dark")
          local before = param_snapshot()
          context.clear_engine_calls()
          pane.tap(x, line)
          assert_equal(param_snapshot(), before, arrangement .. ": line " .. line .. " key " .. x .. " changes nothing")
          assert_equal(#context.engine_calls, 0, arrangement .. ": and sends nothing")
        end
      end
    end
    -- the reverb's freeze offered (3a's seam, planted): 4, toggled 15
    if shows("reverb_freeze") then
      local freeze_id = plant_reverb_freeze(S)
      assert_equal(pane.led(key("reverb_freeze")), 4, arrangement .. ": RF offered, not frozen: 4")
      pane.tap(key("reverb_freeze"))
      assert_equal(params:get(freeze_id), 1, arrangement .. ": RF freezes the reverb")
      assert_equal(pane.led(key("reverb_freeze")), 15, arrangement .. ": frozen: 15")
      pane.tap(key("reverb_freeze"))
      assert_equal(params:get(freeze_id), 0, arrangement .. ": RF again releases it")
      assert_equal(pane.led(key("reverb_freeze")), 4, arrangement .. ": 4")
      -- set elsewhere, it shows within a drift tick (after a first look:
      -- the load's first tick always repaints)
      drift_update()
      params:set(freeze_id, 1)
      drift_update()
      assert_equal(pane.led(key("reverb_freeze")), 15, arrangement .. ": a freeze set elsewhere shows within a tick")
      params:set(freeze_id, 0)
      -- refused while the reverb is bypassed
      params:set("reverb_bypass", 1)
      pane.tap(key("reverb_freeze"))
      assert_equal(params:get(freeze_id), 0, arrangement .. ": RF on a bypassed reverb freezes nothing")
      assert_equal(pane.led(key("reverb_freeze")), 4, arrangement .. ": and its key stays 4")
    end
  end)
end)

test("RF is dark and dead while offered is false", function()
  each_arrangement(function(context, S, pane, arrangement)
    assert_true(not S.lib.fx_hold.offered("reverb"), "3.8 offers no reverb freeze")
    assert_equal(pane.led(KEY_X.reverb_freeze, LINE.keys), 0, arrangement .. ": RF dark")
    local before = param_snapshot()
    context.clear_engine_calls()
    pane.tap(KEY_X.reverb_freeze, LINE.keys)
    assert_equal(param_snapshot(), before, arrangement .. ": RF changes nothing")
    assert_equal(#context.engine_calls, 0, arrangement .. ": and sends nothing")
    -- a param of that name is not enough: offered decides
    S.lib.fx_hold.FX_HOLD.reverb = nil
    params:add{type = "binary", id = "reverb_freeze", name = "reverb freeze", behavior = "toggle", default = 0}
    params:set("reverb_freeze", 1)
    grid_redraw()
    assert_equal(pane.led(KEY_X.reverb_freeze, LINE.keys), 0, arrangement .. ": a param but not offered: dark")
    pane.tap(KEY_X.reverb_freeze, LINE.keys)
    assert_equal(params:get("reverb_freeze"), 1, arrangement .. ": and dead")
  end, {{KEY_X.reverb_freeze, LINE.keys}})
end)

test("with the reverb freeze cut the page draws, and RF is dark and dead", function()
  each_arrangement(function(context, S, pane, arrangement)
    -- the test's own S: the seam planted, then cut: offered answers false
    -- for the reverb and its id is no param, so any read raises
    local freeze_id = plant_reverb_freeze(S)
    local offered = S.lib.fx_hold.offered
    S.lib.fx_hold.offered = function(effect)
      if effect == "reverb" then return false end
      return offered(effect)
    end
    params.lookup[freeze_id] = nil
    assert_true(not pcall(params.get, params, freeze_id), "a read of " .. freeze_id .. " raises")
    local before = param_snapshot()
    grid_redraw()
    drift_update()
    context.clear_engine_calls()
    pane.tap(KEY_X.reverb_freeze, LINE.keys)
    assert_equal(#context.engine_calls, 0, arrangement .. ": the press sends nothing")
    drift_update()
    h.claim_script_errors(context, 0)
    assert_equal(param_snapshot(), before, arrangement .. ": nothing changed")
    assert_equal(pane.led(KEY_X.reverb_freeze, LINE.keys), 0, arrangement .. ": RF dark")
    assert_equal(pane.led(KEY_X.delay_bypass, LINE.keys), 8, arrangement .. ": the page draws")
    assert_equal(pane.led(SET_X.delay, LINE.picks), 15, arrangement .. ": the set key lit")
  end, {{KEY_X.reverb_freeze, LINE.keys}})
end)

test("fm leaves S.fx_last_mix to params_setup", function()
  each_arrangement(function(_, S, pane, arrangement)
    local toggle = S.lib.params_setup.toggle_filter_mix
    local calls = 0
    S.lib.params_setup.toggle_filter_mix = function(...)
      calls = calls + 1
      return toggle(...)
    end
    params:set("filter_mix", 0.6)
    pane.tap(KEY_X.filter_mix, LINE.keys)
    assert_equal(calls, 1, arrangement .. ": fm calls toggle_filter_mix")
    assert_equal(params:get("filter_mix"), 0, arrangement .. ": the mix to 0")
    assert_near(S.fx_last_mix.filter, 0.6, 1e-9, arrangement .. ": remembered by params_setup")
    pane.tap(KEY_X.filter_mix, LINE.keys)
    assert_equal(calls, 2, arrangement .. ": again")
    assert_near(params:get("filter_mix"), 0.6, 1e-9, arrangement .. ": the mix back")
    S.lib.params_setup.toggle_filter_mix = toggle
  end, {{KEY_X.filter_mix, LINE.keys}})
  local file = assert(io.open("lib/grid/pages/fx.lua", "r"))
  local source = file:read("*a")
  file:close()
  assert_true(not source:find("fx_last_mix", 1, true), "the page never names S.fx_last_mix")
end)

test("a param set elsewhere reaches the page within a drift tick", function()
  each_arrangement(function(_, S, pane, arrangement)
    local keys = shown_keys(pane)
    drift_update()  -- the first look
    local function check(what, set, x, y, level)
      set()
      drift_update()
      if pane.shows(x, y) then assert_equal(pane.led(x, y), level, arrangement .. ": " .. what) end
    end
    -- sync's action repaints, but not during a scene transition (#855):
    -- set then, with the reverb set hiding the time line, only its term
    -- of the page's signature can show it
    pick_set(pane, SET_X.reverb)
    capture_scene(1)
    recall_scene(1, 4)  -- step 1 runs now; the clock is never woken
    assert_true(S.scene_transition_active, arrangement .. ": a transition runs")
    drift_update()
    check("sync set during a scene transition", function() params:set("delay_sync", 1) end,
      KEY_X.delay_sync, LINE.keys, 15)
    cancel_scene_transition()
    params:set("delay_sync", 0)
    pick_set(pane, SET_X.delay)
    drift_update()
    check("delay bypassed", function() params:set("delay_bypass", 1) end, KEY_X.delay_bypass, LINE.keys, 2)
    check("reverb bypassed", function() params:set("reverb_bypass", 1) end, KEY_X.reverb_bypass, LINE.keys, 2)
    check("the filter type", function() params:set("filter_type", 3) end, KEY_X.filter_first + 2, LINE.keys, 15)
    check("the filter mix", function() params:set("filter_mix", 0.3) end, KEY_X.filter_mix, LINE.keys, 15)
    check("the interval", function() params:set(S.lib.shimmer.SHIMMER.interval_id, 1) end, INTERVAL_FIRST, LINE.picks, 15)
    check("shimmer on the delay", function() params:set("shimmer_delay", 1) end, fader_x(pane, keys), 5, 15)
    check("ping-pong", function() params:set("delay_pingpong", 1) end, fader_x(pane, keys), 4, 15)
    pick_set(pane, SET_X.reverb)
    check("the reverb's size", function() params:set("reverb_size", 0) end, fader_x(pane, 1), 2, 15)
    check("delay to reverb", function() params:set("delay_to_reverb", 0) end, fader_x(pane, 1), 5, 15)
    pick_set(pane, SET_X.master)
    check("the drift", function() params:set("drift_amount", 0.1) end, fader_x(pane, keys), 5, 15)
    check("the density", function() params:set("master_density", 0.1) end, fader_x(pane, 1), 4, 15)
    local before = pane.device.refresh_count
    for _ = 1, 10 do drift_update() end
    assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": ten idle ticks repaint nothing")
  end)
end)

-- #855: the delay's freeze and the picked set have no term of the
-- signature: the freeze's action repaints the grids whatever else runs,
-- and the set changes only at a press, which repaints
test("the delay's freeze and a set key repaint the grid at once, with no drift tick", function()
  each_arrangement(function(context, S, pane, arrangement)
    capture_scene(1)
    recall_scene(1, 4)  -- even during a scene transition
    local before = pane.device.refresh_count
    params:set("delay_freeze", 1)
    assert_true(pane.device.refresh_count > before, arrangement .. ": the freeze's action repaints")
    assert_equal(pane.led(KEY_X.delay_freeze, LINE.keys), 15, arrangement .. ": DF lit")
    cancel_scene_transition()
    before = pane.device.refresh_count
    pane.tap(SET_X.master, LINE.picks)
    assert_true(pane.device.refresh_count > before, arrangement .. ": a set key's press repaints")
    assert_equal(pane.led(SET_X.master, LINE.picks), 15, arrangement .. ": the master set lit")
  end, {{KEY_X.delay_freeze, LINE.keys}, {SET_X.master, LINE.picks}})
end)

test("the set is per port", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local one = fx_pane(context, "128h", {port = 1})
  local two = fx_pane(context, "128h", {port = 2})
  one.tap(SET_X.reverb, LINE.picks)
  assert_equal(one.led(SET_X.reverb, LINE.picks), 15, "port 1 shows the reverb")
  assert_equal(two.led(SET_X.delay, LINE.picks), 15, "port 2 still the delay")
  assert_equal(two.led(SET_X.reverb, LINE.picks), 4, "port 2's reverb key 4")
  one.tap(16, 2)
  assert_equal(params:get("reverb_size"), 1, "port 1's line 2: the reverb's size")
  two.tap(16, 2)
  assert_near(params:get("delay_feedback"), 0.95, 1e-9, "port 2's line 2: the delay's feedback")
  -- a 256's two panes on FX are one port: one set
  local top = fx_pane(context, "256 top", {port = 3})
  local bottom = fx_pane(context, "256 bottom", {port = 3})
  top.tap(SET_X.master, LINE.picks)
  assert_equal(bottom.led(SET_X.master, LINE.picks), 15, "the 256's bottom pane follows its top pane's set")
  -- the set goes with the grid
  context.grid.unplug(1)
  local again = fx_pane(context, "128h", {port = 1})
  assert_equal(again.led(SET_X.delay, LINE.picks), 15, "a grid plugged in again starts on the delay")
  assert_equal(two.led(SET_X.delay, LINE.picks), 15, "and port 2 is as it was")
  assert_equal(S.lib.grid_core.page(1, 1), S.constants.GRID_PAGES.fx, "port 1 on FX again")
end)

test("DF on a bypassed delay leaves delay_freeze at 0 and its key at 4", function()
  each_arrangement(function(context, _, pane, arrangement)
    params:set("delay_bypass", 1)
    context.clear_engine_calls()
    pane.tap(KEY_X.delay_freeze, LINE.keys)
    assert_equal(params:get("delay_freeze"), 0, arrangement .. ": the freeze refused")
    assert_equal(pane.led(KEY_X.delay_freeze, LINE.keys), 4, arrangement .. ": its key 4")
    for _, call in ipairs(context.calls_named("setDelayFreeze")) do
      assert_equal(call.args[1], 0, arrangement .. ": never a setDelayFreeze(1)")
    end
  end, {{KEY_X.delay_freeze, LINE.keys}})
end)

-- A 64 shows eight columns at a time: the left half the sets, intervals
-- 1-4 and the effects' keys, the right half interval 5 and the filter's
-- keys; the five faders across eight keys on both
test("the 64's halves: left the sets, intervals 1-4 and the effects' keys, right interval 5 and the filter's keys", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = fx_pane(context, "64 left", {half = 1})
  pick_set(pane, SET_X.reverb)
  pane.tap(8, 2)
  assert_equal(params:get("reverb_size"), 1, "left: key 8 of line 2 the size's top")
  pane.tap(INTERVAL_FIRST, LINE.picks)
  assert_equal(params:get(S.lib.shimmer.SHIMMER.interval_id), 1, "left: key 5 of line 6 interval 1")
  pane.tap(KEY_X.reverb_bypass, LINE.keys)
  assert_equal(params:get("reverb_bypass"), 1, "left: key 6 of line 7 the reverb's bypass")
  assert_true(not pane.shows(KEY_X.filter_first, LINE.keys), "left: no filter keys")
  pane.show(S.constants.GRID_PAGES.fx, 1, 2)
  assert_equal(pane.led(9, LINE.picks), 4, "right: interval 5 at 4")
  pane.tap(9, LINE.picks)
  assert_equal(params:get(S.lib.shimmer.SHIMMER.interval_id), 5, "right: key 9 of line 6 interval 5")
  pane.tap(KEY_X.filter_first + 1, LINE.keys)
  assert_equal(params:get("filter_type"), 2, "right: key 10 of line 7 highpass")
  pane.tap(KEY_X.filter_mix, LINE.keys)
  assert_true(params:get("filter_mix") > 0, "right: key 12 the filter's mix on")
  pane.tap(16, 2)
  assert_equal(params:get("reverb_size"), 1, "right: key 16 of line 2 the size's top")
  pane.tap(9, 2)
  assert_equal(params:get("reverb_size"), 0, "right: key 9 of line 2 its bottom")
  assert_equal(pane.led(9, 2), 15, "right: shown at key 9")
end)

test("keys off the page's lines do nothing, and no grid raises nothing", function()
  each_arrangement(function(context, S, pane, arrangement)
    local record = S.lib.grid_pages_fx.record
    local before = param_snapshot()
    local probe = {state = function() return {} end}
    record.press(probe, 0, LINE.keys, 1)
    record.press(probe, 17, LINE.keys, 1)
    record.press(probe, 1, 8, 1)
    record.press(probe, 1.5, LINE.keys, 1)
    record.press(probe, 1, LINE.keys, 0)
    assert_equal(param_snapshot(), before, arrangement .. ": nothing changed")
    h.claim_script_errors(context, 0)
  end)
  load_strata()
  params:set("delay_mix", 0.5)
  drift_update()
  grid_redraw()
end)
end

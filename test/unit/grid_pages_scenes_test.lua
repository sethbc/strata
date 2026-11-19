-- test/unit/grid_pages_scenes_test.lua
-- Grid page 3, scenes (lib/grid/pages/scenes.lua, design §10.5): lines 1
-- and 2 recall (SV held: save), line 3 the picked morph corner's scene,
-- lines 4 and 5 the morph's X and Y faders, line 6 the sequence's length,
-- line 7 SQ, SV, the corners and the gesture recorders, on every
-- arrangement (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_scenes

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane = h.grid_pane

-- The pane's first and last shown column: a half shows eight
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

-- SV: x 2 of line 7, or x 16 on the 64's right half (ruling 58)
local function sv_x(pane)
  return pane.shows(2, 7) and 2 or 16
end

-- The pane x of key k (1 the minimum) of a fader line over the shown
-- columns: the 128v's run up (x 1 is its top key)
local function fader_x(pane, k)
  local first, last = shown_columns(pane)
  if pane.arrangement == "128v" then return last - k + 1 end
  return first + k - 1
end

local function shown_keys(pane)
  local first, last = shown_columns(pane)
  return last - first + 1
end

local function scenes_pane(context, arrangement, opts)
  local S = local_value("S")
  local pane = grid_pane(context, arrangement, opts)
  pane.show(S.constants.GRID_PAGES.scenes)
  return pane
end

-- Each arrangement (or those that show every key of `needs`, {x, y}
-- pairs) on a fresh load, its pane on the scenes page
local function each_arrangement(body, needs)
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = scenes_pane(context, arrangement)
    local shown = true
    for _, key in ipairs(needs or {}) do shown = shown and pane.shows(key[1], key[2]) end
    if shown then body(context, S, pane, arrangement) end
  end
end

-- The values a controller got on cc, in order, comma-joined
local function cc_echoes(controller, cc)
  local values = {}
  for _, message in ipairs(controller.sent) do
    if message[2] == cc then table.insert(values, message[3]) end
  end
  return table.concat(values, ",")
end

-- Counts S.lib.scenes.save's calls (the real save still runs)
local function count_saves(S)
  local counter = {n = 0}
  local real_save = S.lib.scenes.save
  S.lib.scenes.save = function(...)
    counter.n = counter.n + 1
    return real_save(...)
  end
  return counter
end

test("the scenes page is registered at its index", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.scenes]
  assert_true(record ~= nil, "a record at page 3")
  assert_equal(record.name, "scenes")
  assert_equal(record.sides, nil, "one side")
  assert_equal(type(record.faders), "function", "it has fader lines")
  assert_equal(type(record.signature), "function", "and a signature")
  assert_equal(S.lib.grid_pages_scenes.record, record, "the module keeps its record")
end)

test("SV held with a recall key saves that scene and recalls nothing; a recall key alone recalls", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local sv = sv_x(pane)
    local saves = count_saves(S)
    assert_equal(pane.led(sv, 7), 4, arrangement .. ": SV idle at 4")
    pane.press(sv, 7, 1)
    assert_equal(pane.led(sv, 7), 15, arrangement .. ": SV held at 15")
    pane.tap(first, 1)
    assert_true(S.scenes[first].populated, arrangement .. ": SV and line 1's key save scene " .. first)
    assert_true(S.current_scene ~= first, arrangement .. ": and recall nothing")
    pane.tap(first + 1, 2)
    assert_true(S.scenes[first + 1].populated, arrangement .. ": SV and line 2's key save too")
    assert_true(not S.scene_transition_active, arrangement .. ": and start no fade")
    assert_equal(saves.n, 2, arrangement .. ": one save a key")
    pane.press(sv, 7, 0)
    assert_equal(pane.led(sv, 7), 4, arrangement .. ": SV let go: 4")
    pane.tap(first, 1)
    assert_equal(S.current_scene, first, arrangement .. ": line 1's key alone recalls at once")
    assert_equal(saves.n, 2, arrangement .. ": and saves nothing")
  end)
end)

-- #854: a save onto a slot that holds a scene still recalls nothing
test("SV held over a populated slot saves over it and recalls nothing", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local sv = sv_x(pane)
    capture_scene(first); capture_scene(first + 1)
    pane.tap(first + 1, 1)
    assert_equal(S.current_scene, first + 1, arrangement .. ": scene " .. (first + 1) .. " recalled")
    params:set("delay_mix", 0.37)
    local saves = count_saves(S)
    pane.press(sv, 7, 1)
    pane.tap(first, 1)
    pane.tap(first, 2)
    pane.press(sv, 7, 0)
    assert_equal(saves.n, 2, arrangement .. ": one save a key")
    assert_equal(S.current_scene, first + 1, arrangement .. ": the current scene is unchanged")
    assert_true(not S.scene_transition_active, arrangement .. ": no fade started")
    assert_near(params:get("delay_mix"), 0.37, 1e-9, arrangement .. ": nothing recalled over the edit")
    params:set("delay_mix", 0.8)
    pane.tap(first, 1)
    assert_equal(S.current_scene, first, arrangement .. ": SV let go, the key recalls the saved scene")
    assert_near(params:get("delay_mix"), 0.37, 1e-6, arrangement .. ": which holds what was saved")
  end)
end)

test("SV released first: the scene key recalls; a scene key held before SV comes down does nothing", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local sv = sv_x(pane)
    capture_scene(first)
    local saves = count_saves(S)
    pane.tap(sv, 7)
    pane.tap(first, 1)
    assert_equal(S.current_scene, first, arrangement .. ": SV let go first: the key recalls")
    assert_equal(saves.n, 0, arrangement .. ": and saves nothing")
    pane.press(first + 1, 1, 1)  -- an empty slot: recalls nothing
    pane.press(sv, 7, 1)
    pane.press(first + 1, 1, 0)
    pane.press(sv, 7, 0)
    assert_true(not S.scenes[first + 1].populated, arrangement .. ": a key held before SV saves nothing")
    assert_equal(saves.n, 0, arrangement)
  end)
end)

test("SV held across a page change saves nothing", function()
  each_arrangement(function(_, S, pane, arrangement)
    local first = shown_columns(pane)
    local sv = sv_x(pane)
    local pages = S.constants.GRID_PAGES
    capture_scene(first)
    local saves = count_saves(S)
    pane.press(sv, 7, 1)
    pane.show(pages.patterns)
    pane.show(pages.scenes)
    assert_equal(pane.led(sv, 7), 4, arrangement .. ": SV, still down, has lost its role")
    pane.tap(first, 1)
    assert_equal(saves.n, 0, arrangement .. ": the scene key saves nothing")
    assert_equal(S.current_scene, first, arrangement .. ": it recalls")
    pane.press(sv, 7, 0)
  end)
end)

test("on a 64's right half x 16 saves scenes 9-16; on a 128h x 16 does nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local right = scenes_pane(context, "64 right")
  assert_equal(right.led(16, 7), 4, "x 16 on the right half is SV: 4")
  right.press(16, 7, 1)
  assert_equal(right.led(16, 7), 15, "held: 15")
  right.tap(12, 1)
  right.press(16, 7, 0)
  assert_true(S.scenes[12].populated, "x 16 held and scene 12's key: scene 12 saved")
  assert_true(S.current_scene ~= 12, "and not recalled")
  for _, arrangement in ipairs({"128h", "256 top", "256 bottom", "128v"}) do
    context = load_strata(); finish_startup(context)
    S = local_value("S")
    local pane = scenes_pane(context, arrangement)
    local saves = count_saves(S)
    assert_equal(pane.led(16, 7), 0, arrangement .. ": x 16 of line 7 is dark on a full pane")
    pane.press(16, 7, 1)
    pane.tap(12, 1)
    pane.press(16, 7, 0)
    assert_equal(saves.n, 0, arrangement .. ": x 16 is no SV: nothing saved")
    assert_true(not S.scenes[12].populated, arrangement)
  end
end)

test("SV held on grid 1 never makes a scene key of grid 2 save", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local one = scenes_pane(context, "128h")
  local two = scenes_pane(context, "128h", {port = 2})
  capture_scene(3)
  local saves = count_saves(S)
  one.press(2, 7, 1)
  two.tap(3, 1)
  assert_equal(saves.n, 0, "grid 2's scene key saves nothing")
  assert_equal(S.current_scene, 3, "it recalls")
  assert_equal(two.led(2, 7), 4, "grid 2's SV is not lit")
  one.press(2, 7, 0)
end)

test("on a 256 with scenes in both panes each pane's SV saves only from its own pane", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local top = scenes_pane(context, "256 top")
  local bottom = scenes_pane(context, "256 bottom")
  capture_scene(5)
  local saves = count_saves(S)
  top.press(2, 7, 1)
  bottom.tap(5, 1)
  assert_equal(saves.n, 0, "the top's SV: a bottom scene key saves nothing")
  assert_equal(S.current_scene, 5, "it recalls")
  assert_equal(bottom.led(2, 7), 4, "the bottom's SV is not lit")
  top.tap(6, 1)
  assert_true(S.scenes[6].populated, "a top scene key saves")
  top.press(2, 7, 0)
  bottom.press(2, 7, 1)
  bottom.tap(7, 2)
  bottom.press(2, 7, 0)
  assert_true(S.scenes[7].populated, "the bottom's SV saves from the bottom")
end)

-- #452: the scene keys show the core's levels (grid_core_test.lua holds
-- the rule: the next slot, the current scene, the blink)
test("the scene keys show the core's levels (#452)", function()
  each_arrangement(function(context, S, pane, arrangement)
    local core = S.lib.grid_core
    local first, last = shown_columns(pane)
    capture_scene(first); capture_scene(first + 1); capture_scene(first + 2)
    params:set("scene_sequence_length", first + 3)
    params:set("scene_transition_time", 0); params:set("scene_duration", 4)
    params:set("scene_sequencer_enabled", 1)
    context.clock.run_for(1, 0.001)  -- scene `first` playing, the next one next
    assert_equal(S.current_scene, first, arrangement .. ": the sequencer plays scene " .. first)
    local seen = {}
    for x = first, last do
      assert_equal(pane.led(x, 1), core.scene_recall_level(x), arrangement .. ": recall key " .. x)
      assert_equal(pane.led(x, 2), core.scene_fade_level(x), arrangement .. ": fade key " .. x)
      seen[pane.led(x, 1)] = true
    end
    assert_true(seen[15] and seen[10] and seen[8] and seen[2], arrangement .. ": the recall keys show all four levels")
    assert_equal(pane.led(first + 1, 2), 6, arrangement .. ": a saved scene's fade key at 6")
    assert_equal(pane.led(first + 3, 2), 2, arrangement .. ": an empty one's at 2")
    params:set("scene_sequencer_enabled", 0)
  end)
end)

test("a sequenced instant recall lights at once (#49)", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first = shown_columns(pane)
    local second = first + 1
    capture_scene(first); capture_scene(second)
    params:set("scene_sequence_length", second)
    params:set("scene_transition_time", 0); params:set("scene_duration", 4)
    params:set("scene_sequencer_enabled", 1)
    context.clock.run_for(1, 0.001)
    assert_equal(S.current_scene, first, arrangement .. ": the sequencer recalled scene " .. first)
    context.clock.run_for(4, 0.001)  -- at 4 s it recalls the next instantly
    assert_equal(S.current_scene, second, arrangement .. ": the sequencer recalled scene " .. second)
    assert_equal(pane.led(second, 1), 15, arrangement .. ": scene " .. second .. " is lit")
    assert_equal(pane.led(first, 1), 10, arrangement .. ": the previous one is the next (#303)")
    params:set("scene_sequencer_enabled", 0)
    -- recalls from outside the grid: an instant one repaints the grid
    -- once, a smooth one lights its scene at once
    local refreshes = pane.device.refresh_count
    recall_scene(first, 0)
    assert_equal(pane.device.refresh_count, refreshes + 1, arrangement .. ": an instant recall repaints once")
    assert_equal(pane.led(first, 1), 15, arrangement)
    assert_equal(pane.led(second, 1), 8, arrangement)
    recall_scene(second, 2)
    assert_equal(pane.led(second, 1), 15, arrangement .. ": a smooth recall lights its scene as it starts")
    assert_equal(pane.led(first, 1), 8, arrangement .. ": and dims the previous one")
    context.clock.run_for(3, 0.001)
    assert_equal(pane.led(second, 1), 15, arrangement .. ": still lit after the fade")
  end)
end)

test("the sequencer and length LEDs follow a length or start set outside the grid (#49)", function()
  each_arrangement(function(_, _, pane, arrangement)
    local first = shown_columns(pane)
    params:set("scene_sequence_length", first + 5)
    assert_equal(pane.led(first + 5, 6), 8, arrangement .. ": the length's key within it, 8")
    assert_equal(pane.led(first + 6, 6), 2, arrangement .. ": the next beyond it, 2")
    params:set("scene_sequence_length", first + 1)
    assert_equal(pane.led(first + 1, 6), 8, arrangement)
    assert_equal(pane.led(first + 2, 6), 2, arrangement .. ": the keys past it dim at once")
    if pane.shows(1, 7) then
      params:set("scene_sequencer_enabled", 1)
      assert_equal(pane.led(1, 7), 15, arrangement .. ": SQ lights as the sequencer starts")
      params:set("scene_sequencer_enabled", 0)
      assert_equal(pane.led(1, 7), 4, arrangement .. ": and dims as it stops")
    end
  end)
end)

-- #538: norns' Binary:set sends no MIDI-map CC (only ParamSet:delta does),
-- so SQ sets its binary param through set_binary_param, and a controller
-- mapped to it in PARAMS > MAP follows
test("the sequencer key echoes to a MIDI-mapped controller (#538)", function()
  each_arrangement(function(context, _, pane, arrangement)
    local controller = context.midi.plug(1)
    norns.pmap.data.scene_sequencer_enabled = { dev = 1, ch = 1, cc = 40, in_lo = 0, in_hi = 127, out_lo = 0,
      out_hi = 1, echo = true, value = 0 }
    pane.tap(1, 7)
    assert_equal(params:get("scene_sequencer_enabled"), 1, arrangement .. ": SQ turns the sequencer on")
    pane.tap(1, 7)
    assert_equal(params:get("scene_sequencer_enabled"), 0, arrangement .. ": and off")
    assert_equal(cc_echoes(controller, 40), "127,0", arrangement .. ": the controller hears both")
  end, {{1, 7}})
end)

test("scenes 9-16 and lengths 9-16", function()
  each_arrangement(function(context, S, pane, arrangement)
    local core = S.lib.grid_core
    local sv = sv_x(pane)
    pane.press(sv, 7, 1); pane.tap(12, 1); pane.press(sv, 7, 0)
    assert_true(S.scenes[12].populated, arrangement .. ": SV and scene 12's key save scene 12")
    capture_scene(16); S.lib.scenes.set_name(16, "dusk"); grid_redraw()  -- the quantizer's label stays S16
    for x = 9, 16 do
      assert_equal(pane.led(x, 1), core.scene_recall_level(x), arrangement .. ": recall key " .. x)
      assert_equal(pane.led(x, 2), core.scene_fade_level(x), arrangement .. ": fade key " .. x)
    end
    assert_equal(pane.led(12, 1), 8, arrangement .. ": populated scene 12 at 8")
    assert_equal(pane.led(13, 1), 2, arrangement .. ": empty scene 13 at 2")
    local scheduled = {}
    local real_schedule = S.lib.quantize.schedule
    S.lib.quantize.schedule = function(action_key, fn, label)
      table.insert(scheduled, action_key .. " " .. label); fn(); return true
    end
    pane.tap(16, 1)
    assert_equal(S.current_scene, 16, arrangement .. ": (16, 1) recalls scene 16 at once")
    assert_equal(pane.led(16, 1), 15, arrangement .. ": and lights it")
    params:set("scene_transition_time", 2)
    pane.tap(12, 2)
    assert_true(S.scene_transition_active and S.SCENE_TRANSITION.target == 12, arrangement .. ": (12, 2) fades to 12")
    S.lib.quantize.schedule = real_schedule
    assert_equal(table.concat(scheduled, ","), "scene S16,scene S12", arrangement .. ": both through the quantizer")
    context.clock.run_for(2.5)
    pane.tap(16, 6); assert_equal(params:get("scene_sequence_length"), 16, arrangement .. ": (16, 6) length 16")
    pane.tap(9, 6); assert_equal(params:get("scene_sequence_length"), 9, arrangement .. ": (9, 6) length 9")
    pane.tap(12, 6); assert_equal(params:get("scene_sequence_length"), 12, arrangement .. ": (12, 6) length 12")
    for x = 9, 16 do
      assert_equal(pane.led(x, 6), x <= 12 and 8 or 2, arrangement .. ": length key " .. x)
    end
  end, {{9, 1}, {16, 1}})
end)

test("a length key repaints the grid once (#161)", function()
  each_arrangement(function(_, _, pane, arrangement)
    local first = shown_columns(pane)
    local refreshes = pane.device.refresh_count
    pane.press(first + 2, 6, 1)
    assert_equal(params:get("scene_sequence_length"), first + 2, arrangement .. ": the key sets the length")
    assert_equal(pane.device.refresh_count, refreshes + 1, arrangement .. ": and the grid is painted once")
    pane.press(first + 2, 6, 0)
  end)
end)

test("a corner key picks which of morph_a to morph_d line 3 shows and sets, per port", function()
  each_arrangement(function(context, S, pane, arrangement)
    local first, last = shown_columns(pane)
    capture_scene(first + 2)
    grid_redraw()
    -- A at first: morph_a is scene 1
    for x = first, last do
      local level = x == params:get("morph_a") and 15 or (S.scenes[x].populated and 6 or 2)
      assert_equal(pane.led(x, 3), level, arrangement .. ": line 3 shows A's scene, key " .. x)
    end
    assert_equal(pane.led(4, 7), 15, arrangement .. ": cA picked")
    for x = 5, 7 do assert_equal(pane.led(x, 7), 4, arrangement .. ": corner key " .. x .. " not picked") end
    pane.tap(first + 3, 3)
    assert_equal(params:get("morph_a"), first + 3, arrangement .. ": line 3 sets A")
    pane.tap(6, 7)
    assert_equal(pane.led(6, 7), 15, arrangement .. ": cC picked")
    assert_equal(pane.led(4, 7), 4, arrangement)
    assert_equal(params:get("morph_c"), 3, arrangement .. ": C is scene 3 by default")
    assert_equal(pane.led(3, 3), 15, arrangement .. ": line 3 shows C's scene")
    pane.tap(first + 4, 3)
    assert_equal(params:get("morph_c"), first + 4, arrangement .. ": line 3 now sets C")
    assert_equal(params:get("morph_a"), first + 3, arrangement .. ": and leaves A")
    assert_equal(pane.led(first + 4, 3), 15, arrangement)
    assert_equal(pane.led(first + 3, 3), 2, arrangement .. ": A's scene, empty, at 2")
    assert_equal(pane.led(first + 2, 3), 6, arrangement .. ": a populated scene at 6")
    pane.tap(7, 7)
    pane.tap(first, 3)
    assert_equal(params:get("morph_d"), first, arrangement .. ": cD: line 3 sets D")
    pane.tap(5, 7)
    pane.tap(first + 1, 3)
    assert_equal(params:get("morph_b"), first + 1, arrangement .. ": cB: line 3 sets B")
    -- another grid keeps its own corner (A at first)
    local other = scenes_pane(context, "128h", {port = 2})
    assert_equal(other.led(4, 7), 15, arrangement .. ": grid 2 has A picked")
    other.tap(9, 3)
    assert_equal(params:get("morph_a"), 9, arrangement .. ": grid 2's line 3 sets A")
    assert_equal(params:get("morph_b"), first + 1, arrangement .. ": not grid 1's B")
  end, {{4, 7}})
end)

test("the corner shown by a 64's right half follows the corner picked on its left", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = scenes_pane(context, "64 left")
  pane.tap(5, 7)  -- cB
  pane.show(S.constants.GRID_PAGES.scenes, 1, 2)
  pane.tap(11, 3)
  assert_equal(params:get("morph_b"), 11, "the right half's line 3 sets the corner picked on the left")
  assert_equal(pane.led(11, 3), 15)
end)

test("a corner's scene set off the grid shows within a tick", function()
  each_arrangement(function(_, _, pane, arrangement)
    local _, last = shown_columns(pane)
    params:set("morph_a", last)
    drift_update()
    assert_equal(pane.led(last, 3), 15, arrangement .. ": morph_a set elsewhere shows within a tick")
  end)
end)

test("the morph fader and the morph's Y", function()
  each_arrangement(function(_, _, pane, arrangement)
    local keys = shown_keys(pane)
    for _, line in ipairs({{4, "morph"}, {5, "morph_y"}}) do
      local y, id = line[1], line[2]
      pane.tap(fader_x(pane, keys), y)
      assert_near(params:get(id), 1.0, 1e-9, arrangement .. ": line " .. y .. "'s top key sets " .. id .. " to 1")
      assert_equal(pane.led(fader_x(pane, keys), y), 15, arrangement .. ": lit at 15")
      assert_equal(pane.led(fader_x(pane, 1), y), 8, arrangement .. ": the bar at 8")
      pane.tap(fader_x(pane, 1), y)
      assert_near(params:get(id), 0, 1e-9, arrangement .. ": its bottom key to 0")
      assert_equal(pane.led(fader_x(pane, 1), y), 15, arrangement)
      params:set(id, 0.5)
      drift_update()
      local k = fader_position(id, keys)
      assert_equal(pane.led(fader_x(pane, k), y), 15, arrangement .. ": " .. id .. " set elsewhere shows within a tick")
      assert_equal(pane.led(fader_x(pane, keys), y), 0, arrangement .. ": nothing above it")
    end
  end)
end)

test("morph_y set from line 5 is recorded by a gesture recorder as a grid touch", function()
  each_arrangement(function(_, S, pane, arrangement)
    local touches = {}
    S.register_param_touch(function(param_id, source) touches[#touches + 1] = param_id .. ":" .. source end)
    pane.tap(9, 7)
    assert_equal(S.lib.gestures.state(1), "recording", arrangement .. ": G1 records")
    pane.tap(fader_x(pane, shown_keys(pane)), 5)
    assert_equal(table.concat(touches, " "), "morph_y:grid", arrangement .. ": one touch, from the grid")
    local events = S.gestures[1].pattern.event
    assert_true(#events >= 1 and events[#events].id == "morph_y", arrangement .. ": the recorder holds morph_y")
    pane.tap(9, 7)
    assert_equal(S.lib.gestures.state(1), "playing", arrangement .. ": and plays it")
    S.lib.gestures.clear(1)
  end, {{9, 7}})
end)

-- Ruling 73: a recorder key acts at its release: a tap presses once; a
-- 0.5 s hold clears and its release does nothing; two held at once act
-- each at its own release
test("the recorder keys act at their release, two at once each at its own, and a hold clears", function()
  each_arrangement(function(context, S, pane, arrangement)
    local gestures = S.lib.gestures
    for x = 9, 12 do assert_equal(pane.led(x, 7), 2, arrangement .. ": recorder " .. (x - 8) .. " empty at 2") end
    pane.press(9, 7, 1)
    assert_equal(gestures.state(1), "empty", arrangement .. ": a press alone does nothing")
    context.clock.run_for(0.3)
    pane.press(9, 7, 0)
    assert_equal(gestures.state(1), "recording", arrangement .. ": a release within 0.5 s records")
    assert_equal(pane.led(9, 7), 15, arrangement .. ": recording at 15")
    pane.tap(fader_x(pane, shown_keys(pane)), 4)  -- the morph to 1, recorded
    pane.tap(9, 7)
    assert_equal(gestures.state(1), "playing", arrangement .. ": a tap plays")
    assert_equal(pane.led(9, 7), 10, arrangement .. ": playing at 10")
    pane.tap(9, 7)
    assert_equal(gestures.state(1), "stopped", arrangement)
    assert_equal(pane.led(9, 7), 5, arrangement .. ": stopped at 5")
    pane.press(9, 7, 1); context.clock.run_for(0.51)
    assert_equal(gestures.state(1), "empty", arrangement .. ": held 0.5 s: cleared")
    assert_equal(pane.led(9, 7), 2, arrangement)
    pane.press(9, 7, 0)
    assert_equal(gestures.state(1), "empty", arrangement .. ": the release after the clear does nothing")
    -- two held at once
    pane.press(11, 7, 1); pane.press(12, 7, 1)
    pane.press(12, 7, 0)
    assert_equal(gestures.state(4), "recording", arrangement .. ": G4's release presses it")
    assert_equal(gestures.state(3), "empty", arrangement .. ": G3, still down, nothing yet")
    pane.press(11, 7, 0)
    assert_equal(gestures.state(3), "recording", arrangement .. ": G3's release presses it")
    assert_equal(gestures.state(4), "empty", arrangement .. ": which ends G4's empty recording")
    gestures.clear(3)
  end, {{9, 7}})
end)

-- A release acts only for the key pressed in its role
test("a step key held into the scenes page is no recorder key at its release", function()
  each_arrangement(function(_, S, pane, arrangement)
    local pages = S.constants.GRID_PAGES
    pane.show(pages.patterns)
    pane.press(9, 7, 1)  -- voice 7's step 9
    pane.show(pages.scenes)
    pane.press(9, 7, 0)  -- let go on G1
    assert_equal(S.lib.gestures.state(1), "empty", arrangement .. ": G1 records nothing")
    assert_equal(S.patterns[7][9], 0, arrangement .. ": and the step is untouched")
    pane.tap(9, 7)
    assert_equal(S.lib.gestures.state(1), "recording", arrangement .. ": G1's own tap records")
    S.lib.gestures.clear(1)
  end, {{9, 7}})
end)

test("a page change cancels a recorder key's clear", function()
  each_arrangement(function(context, S, pane, arrangement)
    local pages = S.constants.GRID_PAGES
    pane.tap(9, 7)
    assert_equal(S.lib.gestures.state(1), "recording", arrangement)
    pane.press(9, 7, 1)
    pane.show(pages.patterns)
    context.clock.run_for(0.6)
    pane.press(9, 7, 0)
    assert_equal(S.lib.gestures.state(1), "recording", arrangement .. ": the clear held through a page change cleared nothing")
    assert_equal(S.patterns[7][9], 0, arrangement .. ": and the release toggled no step")
    S.lib.gestures.clear(1)
  end, {{9, 7}})
end)

test("line 7: SQ, SV, the corners and the recorders; the rest is dark", function()
  each_arrangement(function(_, S, pane, arrangement)
    local half_sv = not pane.shows(2, 7)
    local expected = {[1] = 4, [2] = 4, [4] = 15, [5] = 4, [6] = 4, [7] = 4, [9] = 2, [10] = 2, [11] = 2, [12] = 2,
      [16] = half_sv and 4 or 0}
    for x = 1, 16 do
      if pane.shows(x, 7) then
        assert_equal(pane.led(x, 7), expected[x] or 0, arrangement .. ": line 7 key " .. x)
      end
    end
    -- the dark keys do nothing: no param, scene, corner or recorder moves
    local function snapshot()
      local parts = {}
      for _, param in ipairs(params.params) do
        -- a voice's params are left out: a drift tick moves a running
        -- voice's pitch, and no key of the page reaches a voice
        if param.id and not param.id:match("^v%d+_") then parts[#parts + 1] = param.id .. "=" .. tostring(params:get(param.id)) end
      end
      for n = 1, S.constants.NUM_SCENES do parts[#parts + 1] = tostring(S.scenes[n].populated) end
      for k = 1, S.constants.NUM_GESTURES do parts[#parts + 1] = S.lib.gestures.state(k) end
      parts[#parts + 1] = tostring(S.current_scene) .. " " .. tostring(S.scene_transition_active)
      parts[#parts + 1] = tostring((S.lib.grid_core.port_state(pane.port).pages.scenes or {}).corner)
      return table.concat(parts, " ")
    end
    local before = snapshot()
    for _, x in ipairs({3, 8, 13, 14, 15}) do
      if pane.shows(x, 7) then pane.tap(x, 7) end
    end
    if not half_sv and pane.shows(16, 7) then pane.tap(16, 7) end
    assert_equal(snapshot(), before, arrangement .. ": dark keys change nothing")
  end)
end)

-- #853: a renamed morph param fails loudly, never silently dropping its
-- line: faders and signature raise naming it, and through the pane engine
-- the failure is contained and printed once
test("a missing morph param raises in faders and signature, contained and printed by the pane engine", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.scenes]
  local state = {}
  local pane_object = {width = 16, offset = 0, state = function() return state end}
  local ids = {}
  for _, line in ipairs(record.faders(pane_object)) do ids[#ids + 1] = line.line .. ":" .. line.id end
  assert_equal(table.concat(ids, " "), "4:morph 5:morph_y", "lines 4 and 5")
  local saved = params.lookup.morph_y
  params.lookup.morph_y = nil
  local ok, err = pcall(record.faders, pane_object)
  params.lookup.morph_y = saved
  assert_true(not ok and tostring(err):find("morph_y", 1, true) ~= nil, "faders raises naming morph_y: " .. tostring(err))
  saved = params.lookup.morph_a
  params.lookup.morph_a = nil
  ok, err = pcall(record.signature, pane_object)
  params.lookup.morph_a = saved
  assert_true(not ok and tostring(err):find("morph_a", 1, true) ~= nil, "signature raises naming morph_a: " .. tostring(err))
  -- on a grid: printed once, and the page's other lines still work
  local pane = scenes_pane(context, "128h")
  saved = params.lookup.morph_y
  params.lookup.morph_y = nil
  grid_redraw(); grid_redraw()
  pane.tap(3, 6)
  params.lookup.morph_y = saved
  h.claim_script_errors(context, 1, "strata: grid page faders failed: ", "morph_y")
  assert_equal(params:get("scene_sequence_length"), 3, "line 6 still sets the length")
end)

-- #853: the page's x bound and line 7 are the pane's line (its sixteen
-- keys, S.lib.grid_pane.LINE_KEYS), never the scene count: with eight
-- scenes the recorders at x 9-12 still light and record, and the scene
-- lines end at x 8
test("with fewer scenes than keys, line 7 keeps its sixteen keys and the scene lines end at the last scene", function()
  local file = assert(io.open(h.repo_root .. "/lib/constants.lua", "r"))
  local source = file:read("*a")
  file:close()
  local patched, count = source:gsub("local NUM_SCENES = 16", "local NUM_SCENES = 8")
  assert_equal(count, 1, "the probe finds NUM_SCENES")
  local context = load_strata({module_sources = {["lib/constants"] = patched}}); finish_startup(context)
  local S = local_value("S")
  assert_equal(S.constants.NUM_SCENES, 8, "eight scenes")
  assert_equal(S.lib.grid_pane.LINE_KEYS, 16, "a pane's line is still sixteen keys")
  local pane = scenes_pane(context, "128h")
  assert_equal(pane.led(9, 7), 2, "G1 at x 9 lights as an empty recorder")
  assert_equal(pane.led(12, 7), 2, "and G4 at x 12")
  pane.tap(9, 7)
  assert_equal(S.lib.gestures.state(1), "recording", "G1's press and release start its recording")
  for x = 9, 16 do
    assert_equal(pane.led(x, 1), 0, "line 1 key " .. x .. " is past the last scene: dark")
    assert_equal(pane.led(x, 6), 0, "line 6 key " .. x .. " too")
  end
  local length = params:get("scene_sequence_length")
  pane.tap(12, 6)
  pane.tap(12, 1)
  assert_equal(params:get("scene_sequence_length"), length, "a length key past the last scene does nothing")
  assert_true(S.current_scene ~= 12, "nor a scene key")
end)

end

-- test/unit/positions_test.lua
-- lib/positions.lua: jumps, loops, bookmarks, the scrub glide and its
-- friction, the grid's position row and bookmark strip
-- Run alone: lua test/run.lua positions

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- Voice 1 (running) and voice 2 (running) on slot 1, holding 16 s; voice 3
-- (stopped) on slot 1 too
local function buffer_voices()
  local context = load_strata()
  finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  for voice_idx = 1, 3 do params:set("v" .. voice_idx .. "_source", S.constants.SOURCE_SYNTH + 1) end
  context.clear_engine_calls()
  return context, S
end

-- The setGrainParam values for one param name, in order, as {voice, value}
local function grain_calls(context, name)
  local sent = {}
  for _, call in ipairs(context.calls_named("setGrainParam")) do
    if call.args[2] == name then table.insert(sent, {voice = call.args[1], value = call.args[3]}) end
  end
  return sent
end

local function last_grain(context, name, engine_voice)
  local value
  for _, each in ipairs(grain_calls(context, name)) do
    if each.voice == engine_voice then value = each.value end
  end
  return value
end

local function loop_of(voice_idx)
  return params:get("v" .. voice_idx .. "_loop_start"), params:get("v" .. voice_idx .. "_loop_length")
end

-- A press's `still` for a direct call (3.9, #865), standing in for the
-- grid page's (its key's role, which the core clears at its pane's page,
-- side or half change): true while the pane shows what it showed at the
-- press. A direct call without one ends only at its release or its port's
-- going
local function pane_still(S, port, pane)
  local view = S.lib.grid_core.view(port, pane)
  return function() return S.lib.grid_core.view(port, pane) == view end
end

test("a jump inside the loop moves buf_pos and resets the scan", function()
  local context, S = buffer_voices()
  params:set("v1_loop_length", 0.5); params:set("v1_loop_start", 0.25)
  context.clear_engine_calls()
  S.lib.positions.jump(1, 0.5)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "(0.5 - 0.25) / 0.5")
  local start, length = loop_of(1)
  assert_near(start, 0.25, 1e-9); assert_near(length, 0.5, 1e-9)
  assert_equal(#grain_calls(context, "t_scanReset"), 1, "one reset")
  assert_equal(last_grain(context, "t_scanReset", 0), 1, "to voice 1")
end)

test("a jump outside the loop resets the loop to the whole slot", function()
  local _, S = buffer_voices()
  params:set("v1_loop_length", 0.5); params:set("v1_loop_start", 0.25)
  S.lib.positions.jump(1, 0.9)
  local start, length = loop_of(1)
  assert_near(start, 0, 1e-9); assert_near(length, 1, 1e-9)
  assert_near(params:get("v1_buf_pos"), 0.9, 1e-9)
end)

test("a stopped voice's jump sets its position and sends nothing", function()
  local context, S = buffer_voices()
  S.lib.positions.jump(3, 0.75)
  assert_near(params:get("v3_buf_pos"), 0.75, 1e-9)
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "no reset for a stopped voice")
  S.lib.positions.jump(1, 2)
  assert_near(params:get("v1_buf_pos"), 1, 1e-9, "a position past the slot stops at its end")
end)

test("set_loop sets the start, then the length, then jumps to the start", function()
  local context, S = buffer_voices()
  S.lib.positions.set_loop(1, 0.25, 0.5)
  local start, length = loop_of(1)
  assert_near(start, 0.25, 1e-9); assert_near(length, 0.25, 1e-9)
  assert_near(params:get("v1_buf_pos"), 0, 1e-9)
  assert_equal(#grain_calls(context, "t_scanReset"), 1)
end)

-- #404 (2): the start goes first, so a loop that moves back and grows
-- keeps its length (a length set first would be cut to what the old start
-- leaves: (0.5, 0.5) would end at (0, 0.5)), as when a grid cell is held
-- and a lower one pressed
test("set_loop from a late loop to an earlier, longer one keeps the length", function()
  local _, S = buffer_voices()
  params:set("v1_loop_length", 0.5); params:set("v1_loop_start", 0.5)
  S.lib.positions.set_loop(1, 0, 0.75)
  local start, length = loop_of(1)
  assert_near(start, 0, 1e-9); assert_near(length, 0.75, 1e-9)
end)

test("a two-key press sets the loop from the lower cell's start to the higher cell's end", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  positions.grid_key(1, 1, 5, 16, 1)
  context.clear_engine_calls()
  positions.grid_key(1, 1, 9, 16, 1)
  local start, length = loop_of(1)
  assert_near(start, 0.25, 1e-9); assert_near(length, 0.3125, 1e-9)
  assert_near(params:get("v1_buf_pos"), 0, 1e-9, "the jump to the loop's own start")
  assert_equal(#grain_calls(context, "t_scanReset"), 1)
  positions.grid_key(1, 1, 9, 16, 0); positions.grid_key(1, 1, 5, 16, 0)
  assert_equal(S.lib.grid_core.port_state(1).positions.held, nil, "both releases ended the held key (#403)")
  params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)

  positions.grid_key(1, 1, 9, 16, 1)
  positions.grid_key(1, 1, 5, 16, 1)
  start, length = loop_of(1)
  assert_near(start, 0.25, 1e-9, "the same loop with the higher key first"); assert_near(length, 0.3125, 1e-9)
end)

local function release_all(positions, cells, voice_idx, ...)
  for _, cell in ipairs({...}) do positions.grid_key(1, voice_idx, cell, cells, 0) end
end

test("a press on a two-key loop's edge cells stays inside it; the next cell resets it", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  local function pair(cells, lo, hi)
    params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)
    positions.grid_key(1, 1, lo, cells, 1); positions.grid_key(1, 1, hi, cells, 1)
    release_all(positions, cells, 1, hi, lo)
    local start, length = loop_of(1)
    assert_near(start, (lo - 1) / cells, 1e-9, "pair " .. lo .. "-" .. hi .. " start")
    assert_near(length, (hi - lo + 1) / cells, 1e-9, "pair " .. lo .. "-" .. hi .. " length")

    positions.grid_key(1, 1, lo, cells, 1); release_all(positions, cells, 1, lo)
    local kept_start, kept_length = loop_of(1)
    assert_near(kept_start, start, 1e-9, "press lo keeps the start"); assert_near(kept_length, length, 1e-9)
    assert_near(params:get("v1_buf_pos"), 0, 1e-6, "lo is the loop's start")

    positions.grid_key(1, 1, hi, cells, 1); release_all(positions, cells, 1, hi)
    kept_start, kept_length = loop_of(1)
    assert_near(kept_start, start, 1e-9, "press hi keeps the start"); assert_near(kept_length, length, 1e-9)
    assert_near(params:get("v1_buf_pos"), (hi - lo) / (hi - lo + 1), 1e-6, "hi is the loop's last cell")

    if hi < cells then
      positions.grid_key(1, 1, hi + 1, cells, 1); release_all(positions, cells, 1, hi + 1)
      local reset_start, reset_length = loop_of(1)
      assert_near(reset_start, 0, 1e-9, "the next cell resets the loop (" .. lo .. "-" .. hi .. ")")
      assert_near(reset_length, 1, 1e-9)
    end
  end
  for lo = 1, 15 do
    for hi = lo + 1, 16 do pair(16, lo, hi) end
  end
  pair(8, 3, 6)
end)

test("a scan hold or a held position key ends when its grid changes page or goes away", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  context.clear_engine_calls()
  positions.strip_key(1, 1, "hold", 1, 1, pane_still(S, 1, 1))
  assert_equal(last_grain(context, "scanHold", 0), 1, "the hold key holds the scan")
  context.clock.run_for(0.2)
  assert_equal(#grain_calls(context, "scanHold"), 1, "still held: nothing more sent")
  S.lib.grid_core.set_page(1, 1)
  context.clock.run_for(0.1)
  assert_equal(last_grain(context, "scanHold", 0), 0, "a page change ends it within a tick")
  assert_equal(#grain_calls(context, "scanHold"), 2, "sent once")
  context.clock.run_for(0.5)
  assert_equal(#grain_calls(context, "scanHold"), 2, "and not again")

  -- the grid goes away
  S.lib.grid_core.set_page(1, 5)
  context.clear_engine_calls()
  positions.strip_key(1, 1, "hold", 1)
  context.grid.unplug(1)
  context.clock.run_for(0.1)
  assert_equal(last_grain(context, "scanHold", 0), 0, "a removed grid ends it")
  assert_equal(positions.strip_level(1, "hold"), 4, "and the key is no longer lit")

  -- a held position key ends with the page too
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  positions.grid_key(1, 1, 5, 16, 1, 1, pane_still(S, 1, 1))
  S.lib.grid_core.set_page(1, 1)
  context.clock.run_for(0.1)
  S.lib.grid_core.set_page(1, 5)
  positions.grid_key(1, 1, 9, 16, 1)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "a jump to cell 9")
  local start, length = loop_of(1)
  assert_near(start, 0, 1e-9, "the loop unchanged"); assert_near(length, 1, 1e-9)
end)

-- 3.8: a press record keeps the pane it came from and (3.9, #865) its
-- still, so a key held on a 256's lower pane lives while that pane's still
-- holds, whatever the upper shows
test("a press on a 256's lower pane ends with the lower pane's page change, not the upper's", function()
  local context, S = buffer_voices()
  local positions, grid_core, pages = S.lib.positions, S.lib.grid_core, S.constants.GRID_PAGES
  context.grid.plug(1, 16, 16)
  grid_core.set_page(1, pages.patterns, 1)
  grid_core.set_page(1, pages.positions, 2)
  context.clear_engine_calls()
  positions.strip_key(1, 1, "hold", 1, 2, pane_still(S, 1, 2))
  positions.strip_key(1, 2, "store", 1, 2, pane_still(S, 1, 2))
  positions.grid_key(1, 1, 5, 16, 1, 2, pane_still(S, 1, 2))
  context.clock.run_for(0.2)
  assert_equal(positions.holds_scan(1, "grid:1"), true, "the lower pane's hold lives through the ticks")
  assert_equal(positions.strip_level(2, "store", 1), positions.LEVELS.key_down, "and its store")
  -- the upper pane's page change leaves the lower pane's keys alone
  grid_core.set_page(1, pages.faders, 1)
  context.clock.run_for(0.2)
  assert_equal(positions.holds_scan(1, "grid:1"), true, "the upper pane's page change ends no hold")
  assert_equal(positions.strip_level(2, "store", 1), positions.LEVELS.key_down, "nor the store")
  positions.grid_key(1, 1, 9, 16, 1, 2)
  local start, length = loop_of(1)
  assert_near(start, 0.25, 1e-9, "the held cell 5 and cell 9 set the loop")
  assert_near(length, 0.3125, 1e-9)
  positions.grid_key(1, 1, 9, 16, 0, 2)
  -- the lower pane's own page change ends them within a tick
  grid_core.set_page(1, pages.patterns, 2)
  context.clock.run_for(0.1)
  assert_equal(positions.holds_scan(1, "grid:1"), false, "the lower pane's page change ends its hold")
  assert_equal(last_grain(context, "scanHold", 0), 0, "scanHold 0 sent")
  assert_equal(positions.strip_level(2, "store", 1), positions.LEVELS.key_up, "and its store")
  grid_core.set_page(1, pages.positions, 2)
  positions.grid_key(1, 1, 13, 16, 1, 2)
  assert_near(params:get("v1_buf_pos"), 0.75, 1e-9, "a jump to cell 13: no stale anchor")
  positions.grid_key(1, 1, 13, 16, 0, 2); positions.grid_key(1, 1, 5, 16, 0, 2)
  -- a press without a pane is pane 1's: the lower pane's page leaves it alone
  grid_core.set_page(1, pages.positions, 1)
  positions.strip_key(1, 1, "hold", 1, nil, pane_still(S, 1, 1))
  grid_core.set_page(1, pages.patterns, 2)
  context.clock.run_for(0.1)
  assert_equal(positions.holds_scan(1, "grid:1"), true, "pane 1's hold, with no pane given")
  grid_core.set_page(1, pages.patterns, 1)
  context.clock.run_for(0.1)
  assert_equal(positions.holds_scan(1, "grid:1"), false, "ended by pane 1's page change")
end)

-- #851, then #865: a press record keeps its pane and its still, so whether
-- it is stale never depends on a view's text: positions reads no view at
-- all (grid_core.view raises here), only each press's still
test("a lower pane's press lives through the ticks while its still holds, and reads no view", function()
  local context, S = buffer_voices()
  local positions, grid_core, pages = S.lib.positions, S.lib.grid_core, S.constants.GRID_PAGES
  context.grid.plug(1, 16, 16)
  grid_core.set_page(1, pages.patterns, 1)
  grid_core.set_page(1, pages.positions, 2)
  local view = grid_core.view
  grid_core.view = function() error("positions read a view") end
  local held = true
  local function still() return held end
  local ok, problem = pcall(function()
    positions.strip_key(1, 1, "hold", 1, 2, still)
    positions.strip_key(1, 2, "store", 1, 2, still)
    positions.grid_key(1, 1, 5, 16, 1, 2, still)
    context.clock.run_for(0.2)
    assert_equal(positions.holds_scan(1, "grid:1"), true, "the lower pane's hold lives")
    assert_equal(positions.strip_level(2, "store", 1), positions.LEVELS.key_down, "and its store")
    positions.grid_key(1, 1, 9, 16, 1, 2, still)
    local start, length = loop_of(1)
    assert_near(start, 0.25, 1e-9, "the held cell 5 lives: cells 5 and 9 set the loop")
    assert_near(length, 0.3125, 1e-9)
    positions.grid_key(1, 1, 9, 16, 0, 2)
    held = false  -- the keys' release is lost
    context.clock.run_for(0.1)
    assert_equal(positions.holds_scan(1, "grid:1"), false, "a still that says false ends the hold within a tick")
    assert_equal(positions.strip_level(2, "store", 1), positions.LEVELS.key_up, "and the store")
    positions.grid_key(1, 1, 13, 16, 1, 2)
    assert_near(params:get("v1_buf_pos"), 0.75, 1e-9, "and the held cell: the next press jumps")
  end)
  grid_core.view = view
  if not ok then error(problem, 0) end
end)

-- Both panes of a 256 can show a voice's store and hold keys (positions'
-- second side): each is held per pane, so the key down in one pane lasts
-- through the other pane's release or page change, in either order
test("a voice's store or hold held in both panes of a 256 lasts until its last pane lets go", function()
  local context, S = buffer_voices()
  local positions, grid_core, pages = S.lib.positions, S.lib.grid_core, S.constants.GRID_PAGES
  context.grid.plug(1, 16, 16)
  grid_core.set_page(1, pages.positions, 1); grid_core.set_page(1, pages.positions, 2)
  local function down(key, pane) positions.strip_key(1, 1, key, 1, pane, pane_still(S, 1, pane)) end
  for _, first in ipairs({1, 2}) do
    local second = 3 - first
    down("store", first); down("store", second)
    down("hold", first); down("hold", second)
    positions.strip_key(1, 1, "store", 0, second); positions.strip_key(1, 1, "hold", 0, second)
    assert_equal(positions.strip_level(1, "store", 1), positions.LEVELS.key_down, first .. " first: pane " .. first .. "'s store is still down")
    assert_equal(positions.holds_scan(1, "grid:1"), true, first .. " first: and its hold")
    -- the other pane's page change ends its keys, never the first's
    down("store", second); down("hold", second)
    grid_core.set_page(1, pages.patterns, second)
    context.clock.run_for(0.1)
    assert_equal(positions.strip_level(1, "store", 1), positions.LEVELS.key_down, first .. " first: a page change of pane " .. second .. " leaves the store")
    assert_equal(positions.holds_scan(1, "grid:1"), true, first .. " first: and the hold")
    params:set("v1_buf_pos", 0.6)
    positions.strip_key(1, 1, 3, 1, first); positions.strip_key(1, 1, 3, 0, first)
    assert_near(positions.bookmark(1, 3), 0.6, 0.05, first .. " first: the store still stores")
    positions.strip_key(1, 1, "store", 0, first); positions.strip_key(1, 1, "hold", 0, first)
    assert_equal(positions.strip_level(1, "store", 1), positions.LEVELS.key_up, first .. " first: the last release ends the store")
    assert_equal(positions.holds_scan(1, "grid:1"), false, first .. " first: and the hold")
    grid_core.set_page(1, pages.positions, second)
  end
end)

test("only buffer voices answer position keys; a stopped one keeps its new position", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v1_source", 1)
  context.clear_engine_calls()
  local before = params:get("v1_buf_pos")
  positions.grid_key(1, 1, 5, 16, 1)
  assert_equal(params:get("v1_buf_pos"), before, "a synth voice's position is unchanged")
  assert_equal(#context.engine_calls, 0, "no engine call")
  positions.grid_key(1, 1, 5, 16, 0)
  positions.grid_key(1, 3, 5, 16, 1)
  assert_near(params:get("v3_buf_pos"), 0.25, 1e-9, "a stopped buffer voice moves")
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "and sends no reset")
  positions.grid_key(1, 8, 5, 16, 1)
  positions.grid_key(1, 1, 0, 16, 1)
  positions.grid_key(1, 3, 17, 16, 1)
  assert_near(params:get("v3_buf_pos"), 0.25, 1e-9, "a cell outside the row is ignored")
end)

-- 3.8 (ruling 56): every layout's lines are one voice each, so a position
-- press never picks the grid voice (the faders page's voice keys do)
test("a position press never changes the grid voice", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v4_source", 1)
  params:set("v5_source", S.constants.SOURCE_INPUT)
  local plugged = {[1] = {16, 16}, [2] = {16, 8}, [3] = {8, 16}, [4] = {8, 8}}
  for port, size in pairs(plugged) do context.grid.plug(port, size[1], size[2]) end
  for port = 1, 4 do
    for _, voice_idx in ipairs({1, 2, 3, 4, 5}) do
      S.grid_voice_select = 6
      positions.grid_key(port, voice_idx, 5, 16, 1); positions.grid_key(port, voice_idx, 5, 16, 0)
      assert_equal(S.grid_voice_select, 6, "port " .. port .. ", voice " .. voice_idx .. ": the grid voice stays")
    end
  end
  assert_near(params:get("v3_buf_pos"), 0.25, 1e-9, "the presses still jump")
end)

test("a scene recall that switches a running voice's source forgets its last recalled bookmark", function()
  local context, S = buffer_voices()
  params:set("v1_source", 1)
  capture_scene(1)  -- voice 1 on the synth
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.positions.recall_bookmark(1, 3)
  assert_equal(S.lib.positions.last_recalled(1), 3)
  assert_true(S.voices[1].active, "voice 1 runs")
  recall_scene(1, 0)
  assert_equal(S.voices[1].source, 1, "the recall switched the source")
  assert_equal(S.lib.positions.last_recalled(1), nil, "the level-10 key is forgotten")
end)

test("a scene recall that switches a stopped voice's source forgets its last recalled bookmark", function()
  local context, S = buffer_voices()
  params:set("v1_source", 1)
  toggle_voice(1)
  assert_true(not S.voices[1].active, "voice 1 is stopped")
  capture_scene(1)  -- voice 1 stopped, on the synth
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  S.lib.positions.recall_bookmark(1, 2)
  assert_equal(S.lib.positions.last_recalled(1), 2)
  recall_scene(1, 0)
  assert_equal(S.voices[1].source, 1, "the recall switched the source")
  assert_true(not S.voices[1].active, "voice 1 is still stopped")
  assert_equal(S.lib.positions.last_recalled(1), nil, "the mark is forgotten")
  assert_equal(S.lib.positions.strip_level(1, 2), 0, "a voice on the synth has a dark strip (#445)")
end)

-- #404 (10): each hook forgets the mark on its own. A scene recall runs
-- only the grain-restart hook (a running voice); a stopped voice's source
-- param runs only the source-change hook. Either way, a voice whose source
-- comes back shows no recalled mark (the source check alone would show it)
test("a running voice whose source returns through scene recalls shows no recalled mark", function()
  local _, S = buffer_voices()
  params:set("v1_source", 1)
  capture_scene(1)  -- voice 1 running, on the synth
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  capture_scene(2)  -- voice 1 running, on the buffer
  S.lib.positions.recall_bookmark(1, 3)
  assert_true(S.voices[1].active, "voice 1 runs")
  recall_scene(1, 0)
  assert_equal(S.voices[1].source, 1, "the first recall left the buffer")
  recall_scene(2, 0)
  assert_equal(S.voices[1].source, S.constants.SOURCE_SYNTH + 1, "the second came back")
  assert_equal(S.lib.positions.last_recalled(1), nil, "the grain restart forgot it")
  assert_equal(S.lib.positions.strip_level(1, 3) ~= 10, true, "no recalled level")
end)

test("a stopped voice whose source returns through its param shows no recalled mark", function()
  local _, S = buffer_voices()
  local buffer_source = S.constants.SOURCE_SYNTH + 1
  toggle_voice(1)
  assert_true(not S.voices[1].active, "voice 1 is stopped")
  S.lib.positions.recall_bookmark(1, 2)
  assert_equal(S.lib.positions.last_recalled(1), 2)
  params:set("v1_source", buffer_source + 1)   -- another slot
  params:set("v1_source", buffer_source)       -- and back
  assert_equal(S.lib.positions.last_recalled(1), nil, "the source change forgot it")
end)

test("a stopped voice's recalled mark shows again when two scene recalls bring back the source it was recalled on", function()
  local context, S = buffer_voices()
  params:set("v1_source", 1)
  toggle_voice(1)
  capture_scene(1)  -- voice 1 stopped, on the synth
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  capture_scene(2)  -- voice 1 stopped, on the buffer
  S.lib.positions.recall_bookmark(1, 2)
  recall_scene(1, 0)
  assert_equal(S.voices[1].source, 1, "the first recall left the buffer")
  assert_equal(S.lib.positions.last_recalled(1), nil, "no mark on the synth")
  recall_scene(2, 0)
  assert_equal(S.voices[1].source, S.constants.SOURCE_SYNTH + 1, "the second recall came back")
  assert_true(not S.voices[1].active, "voice 1 is still stopped")
  assert_equal(S.lib.positions.last_recalled(1), 2, "the mark shows while the voice has its source (no hook ran)")
  assert_equal(S.lib.positions.strip_level(1, 2), 10)
end)

test("a row's LED levels are built once while nothing in it changes, on a clock that moves (#398)", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  local calls = 0
  local real_bins = S.lib.waveforms.bins
  S.lib.waveforms.bins = function(...) calls = calls + 1; return real_bins(...) end
  local real_time, tick = util.time, 0
  util.time = function() tick = tick + 1e-6; return real_time() + tick end  -- the device's clock moves between calls
  for cell = 1, 16 do positions.grid_level(1, cell, 16) end
  assert_equal(calls, 1, "one bins read for 16 cells")
  for cell = 1, 16 do positions.grid_level(1, cell, 16) end
  assert_equal(calls, 1, "and still one for the next redraw: nothing changed")
  util.time = real_time
  positions.jump(1, 0.5)
  assert_equal(positions.grid_level(1, 9, 16), 15, "a moved head shows at once")
  positions.grid_key(1, 1, 3, 16, 1)
  assert_equal(positions.grid_level(1, 3, 16), 15, "a pressed cell too (the jump moved the head there)")
  S.buffers[1].seconds = 0
  assert_equal(positions.grid_level(1, 3, 16), 0, "an emptied slot goes dark")
end)

test("bookmarks default to the quarters and are scene fields that crossfade", function()
  local context, S = buffer_voices()
  for voice_idx = 1, S.constants.NUM_VOICES do
    for n, expected in ipairs({0, 0.25, 0.5, 0.75}) do
      assert_near(params:get("v" .. voice_idx .. "_bookmark_" .. n), expected, 1e-9)
    end
  end
  assert_equal(S.constants.SCENE_DATA_VERSION, 10)  -- 3.8: format 10
  params:set("v1_bookmark_2", 0.75)
  capture_scene(1)
  assert_near(S.scenes[1].data.voices[1].values.bookmark_2, 0.75, 1e-9, "the scene captures it")
  params:set("v1_bookmark_2", 0.25)
  recall_scene(1, 1)
  context.clock.run_for(0.5)
  local halfway = params:get("v1_bookmark_2")
  assert_true(halfway > 0.3 and halfway < 0.7, "crossfading at 0.5 s, got " .. halfway)
  context.clock.run_for(2)
  assert_near(params:get("v1_bookmark_2"), 0.75, 1e-9, "ends at the scene's value")

  S.scenes[3] = h.deep_copy(S.scenes[1])
  for voice_idx = 1, S.constants.NUM_VOICES do
    for n = 1, 4 do S.scenes[3].data.voices[voice_idx].values["bookmark_" .. n] = nil end
  end
  fill_scene(S.scenes[3])
  assert_true(validate_scene(S.scenes[3]), "the migrated scene validates")
  recall_scene(3, 0)
  for n, expected in ipairs({0, 0.25, 0.5, 0.75}) do
    assert_near(params:get("v1_bookmark_" .. n), expected, 1e-9, "version 3 scene: bookmark " .. n)
  end
end)

test("a scene with a bookmark outside 0-1 is rejected", function()
  local _, S = buffer_voices()
  capture_scene(1)
  local function with(value)
    local scene = h.deep_copy(S.scenes[1])
    scene.data.voices[1].values.bookmark_1 = value
    return validate_scene(scene)
  end
  assert_true(not with(1.5), "1.5 is out")
  assert_true(not with(-0.1), "-0.1 is out")
  assert_true(with(1), "1 is in")
  assert_true(with(0), "0 is in")
end)

test("bookmarks round-trip through a PSET in any order", function()
  local context, S = buffer_voices()
  local path = context.data_dir .. "strata-bookmarks.pset"
  for n, value in ipairs({0.1, 0.2, 0.3, 0.4}) do params:set("v2_bookmark_" .. n, value) end
  params:write(path)
  local lines = {}
  for line in io.lines(path) do table.insert(lines, line) end
  local shuffled = {}  -- every line once, in reverse
  for index = #lines, 1, -1 do table.insert(shuffled, lines[index]) end
  local file = io.open(path, "w"); file:write(table.concat(shuffled, "\n"), "\n"); file:close()
  for n = 1, 4 do params:set("v2_bookmark_" .. n, 0.9) end
  params:read(path)
  for n, value in ipairs({0.1, 0.2, 0.3, 0.4}) do
    assert_near(params:get("v2_bookmark_" .. n), value, 1e-9, "bookmark " .. n)
  end
  assert_near(S.voices[2].values.bookmark_3, 0.3, 1e-9, "stored too")
end)

test("store_bookmark takes the playhead, or buf_pos mapped into the loop when stopped", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v1_buf_pos", 0.25); params:set("v1_buf_scan", 1.6)  -- a speed: 0.1 of the 16 s slot a second
  S.lib.playheads.reset(1)
  context.clock.run_for(2)
  local playhead = S.lib.playheads.position(1)
  assert_near(playhead, 0.45, 1e-6)
  positions.store_bookmark(1, 2)
  assert_near(params:get("v1_bookmark_2"), playhead, 1e-6, "the playhead")
  assert_near(positions.bookmark(1, 2), playhead, 1e-6)

  params:set("v3_loop_length", 0.5); params:set("v3_loop_start", 0.25); params:set("v3_buf_pos", 0.5)
  positions.store_bookmark(3, 4)
  assert_near(params:get("v3_bookmark_4"), 0.5, 1e-9, "0.25 + 0.5 x 0.5")
  assert_equal(positions.bookmark(1, 5), nil, "no bookmark 5")
  assert_equal(positions.bookmark(8, 1), nil, "no voice 8")
end)

test("recall_bookmark jumps and remembers the last recalled", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  assert_equal(positions.last_recalled(1), nil)
  positions.recall_bookmark(1, 3)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9)
  assert_equal(positions.last_recalled(1), 3)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 2)
  assert_equal(positions.last_recalled(1), nil, "a source switch forgets it")
end)

test("a voice sync sends scrubRate 0 and scanHold 0", function()
  local context, S = buffer_voices()
  context.clear_engine_calls()
  toggle_voice(3)
  local source_at, rate_at, hold_at
  for index, call in ipairs(context.engine_calls) do
    if call.name == "setGrainSource" and call.args[1] == 2 then source_at = source_at or index end
    if call.name == "setGrainParam" and call.args[1] == 2 then
      if call.args[2] == "scrubRate" then rate_at = index; assert_equal(call.args[3], 0) end
      if call.args[2] == "scanHold" then hold_at = index; assert_equal(call.args[3], 0) end
    end
  end
  assert_true(source_at and rate_at and hold_at and source_at < rate_at and source_at < hold_at,
    "both after the source")
  assert_true(S.lib.positions.scrub_rate(3) == 0 and S.lib.positions.scan_held(3) == false, "and the state agrees")
end)

-- Voice 1's ring turns from buf_pos 0.2 at a speed (loop fractions a second)
-- for `seconds`, one tick every 0.01 s; the last tick is at the end
local function fling(context, S, speed, seconds)
  local position = 0.2
  params:set("v1_buf_pos", position)
  for _ = 1, math.floor(seconds / 0.01 + 0.5) do
    context.clock.run_for(0.01)
    position = position + speed * 0.01
    params:set("v1_buf_pos", position)
    S.lib.positions.scrub_turned(1)
  end
end

test("a fling glides and decays with the friction; 100% never glides", function()
  local context, S = buffer_voices()
  assert_equal(params:get("scrub_friction"), 100, "the default is 100%")
  assert_equal(param_default("scrub_friction"), 100)
  local low, high = param_range("scrub_friction")
  assert_equal(low, 0); assert_equal(high, 100)
  fling(context, S, 0.1, 0.3)
  context.clock.run_for(1)
  assert_equal(#grain_calls(context, "scrubRate"), 0, "100%: the ring is direct, nothing glides")

  params:set("scrub_friction", 50)  -- tau = 4 x 0.5 = 2 s
  context.clear_engine_calls()
  fling(context, S, 0.1, 0.3)
  context.clock.run_for(0.08 + 0.001)
  local first = last_grain(context, "scrubRate", 0)
  assert_near(first, 0.1, 0.02, "the glide starts at the ring's speed over the last 0.1 s")
  assert_near(S.lib.positions.scrub_rate(1), first, 1e-12, "and positions says so")
  context.clock.run_for(2 * math.log(2))
  local halved = last_grain(context, "scrubRate", 0)
  assert_near(halved / first, 0.5, 0.05, "halves in 2 ln 2 s")
  context.clock.run_for(30)
  assert_equal(last_grain(context, "scrubRate", 0), 0, "stops")
  assert_equal(S.lib.positions.scrub_rate(1), 0)
  local count = #grain_calls(context, "scrubRate")
  context.clock.run_for(2)
  assert_equal(#grain_calls(context, "scrubRate"), count, "and sends nothing more")
  for _, each in ipairs(grain_calls(context, "scrubRate")) do
    assert_true(each.value == 0 or math.abs(each.value) >= 0.001, "never a value below 0.001 but 0")
  end
end)

-- An error inside the glide's clock never ends it: it is printed once with
-- its traceback and the glide runs on to its end (#517)
test("an error inside the glide is printed once and the glide runs on to its end (#517)", function()
  local context, S = buffer_voices()
  params:set("scrub_friction", 50)   -- tau 2 s
  local real_set_grain = engine.setGrainParam
  local failures, sends = 0, 0
  local failing = function() return true end
  engine.setGrainParam = function(voice, name, value)
    if name == "scrubRate" then
      sends = sends + 1
      if failing(sends) then failures = failures + 1; error("glide boom") end
    end
    return real_set_grain(voice, name, value)
  end
  local function reports()
    local count, traced = 0, false
    for _, line in ipairs(context.printed) do
      if line:find("strata: scrub glide failed: ", 1, true) == 1 then
        count = count + 1
        traced = traced or line:find("stack traceback", 1, true) ~= nil
      end
    end
    return count, traced
  end
  local ok, problem = pcall(function()
    fling(context, S, 0.1, 0.3)
    context.printed = {}
    context.clock.run_for(30)   -- every send of the glide raises
    assert_equal(#context.clock.take_errors(), 0, "the scheduler reported no clock error")
    assert_true(failures > 10, "the glide ran on through its failing steps (" .. failures .. ")")
    local count, traced = reports()
    assert_equal(count, 1, "the same error on every step prints once")
    assert_true(traced, "with its traceback")
    assert_equal(S.lib.positions.scrub_rate(1), 0, "and the glide still decayed to its end")
    local ended = failures
    context.clock.run_for(2)
    assert_equal(failures, ended, "then nothing more runs")
    -- one failing step, the third send of the next glide: after its good
    -- steps the error prints again, and the glide sends the rest of its rates
    local first_send = sends
    failing = function(count) return count == first_send + 3 end
    context.clear_engine_calls()
    fling(context, S, 0.1, 0.3)
    context.clock.run_for(30)
    assert_equal(failures, ended + 1, "one step failed")
    assert_equal(reports(), 2, "the error after good steps prints again")
    assert_equal(#context.clock.take_errors(), 0)
    local rates = grain_calls(context, "scrubRate")
    assert_true(#rates > 10, "the glide went on after its failed step (" .. #rates .. " sends)")
    assert_equal(rates[#rates].value, 0, "and ended at 0")
  end)
  engine.setGrainParam = real_set_grain
  if not ok then error(problem, 0) end
  h.claim_script_errors(context, 2, "strata: scrub glide failed: ", "glide boom")  -- the two it caused (#473)
end)

-- #870: the glide's clock runs on the clock helper (S.lib.clocks), so a
-- jump that ends the glide as the clock's wake is posted retires it
test("the glide's clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  local context, S = buffer_voices()
  params:set("scrub_friction", 0)
  local clocks = S.lib.clocks
  local real_run, started = clocks.run, {}
  clocks.run = function(fn) local handle = real_run(fn); started[#started + 1] = handle; return handle end
  local ok, problem = pcall(function()
    -- a fling, then the glide: its clock sleeps a playhead update at a time
    fling(context, S, 0.2, 0.3)
    context.clock.run_for(0.2)
    assert_true(S.lib.positions.scrub_rate(1) > 0.05, "gliding")
    assert_equal(#started, 1, "one glide clock, on the helper")
    local handle = started[1]
    context.clock.advance_until(handle.id, function() S.lib.positions.jump(1, 0.5) end)
    assert_equal(#context.clock.take_errors(), 0, "no clock error at the wake")
    assert_equal(clock.threads[handle.id], nil, "the clock ended at its wake")
    assert_equal(clocks.retired[handle.id], nil, "and the helper forgot it")
    context.clear_engine_calls()
    context.clock.run_for(2)
    assert_equal(#grain_calls(context, "scrubRate"), 0, "nothing more is sent")
    assert_equal(S.lib.positions.scrub_rate(1), 0, "the glide stays ended")
    -- the next fling starts its own clock and glides
    fling(context, S, 0.2, 0.3)
    context.clock.run_for(0.2)
    assert_true(S.lib.positions.scrub_rate(1) > 0.05, "the next fling glides")
    assert_equal(#started, 2, "on a clock of its own")
  end)
  clocks.run = real_run
  if not ok then error(problem, 0) end
end)

test("a new turn, a jump or a source switch ends the glide at once", function()
  local context, S = buffer_voices()
  params:set("scrub_friction", 0)
  local function glide()
    fling(context, S, 0.2, 0.3)
    context.clock.run_for(0.2)
    assert_true(S.lib.positions.scrub_rate(1) > 0.05, "gliding")
    context.clear_engine_calls()
  end
  glide()
  S.lib.positions.scrub_turned(1)
  assert_equal(last_grain(context, "scrubRate", 0), 0, "a new turn")
  assert_equal(S.lib.positions.scrub_rate(1), 0)
  context.clock.run_for(5)
  assert_equal(S.lib.positions.scrub_rate(1), 0, "and the turn alone does not restart it")

  glide()
  S.lib.positions.jump(1, 0.5)
  assert_equal(last_grain(context, "scrubRate", 0), 0, "a jump")
  assert_equal(S.lib.positions.scrub_rate(1), 0)

  glide()
  params:set("v1_source", S.constants.SOURCE_SYNTH + 2)
  assert_equal(last_grain(context, "scrubRate", 0), 0, "a source switch")
  assert_equal(S.lib.positions.scrub_rate(1), 0)
end)

-- Slot 1 with every peak 0.5
local function half_peaks(S)
  S.lib.waveforms.bins = function(_, n)
    local bins = {}
    for index = 1, n do bins[index] = 0.5 end
    return bins
  end
end

test("grid levels: empty 0, outside the loop 1-3, inside 4-8, held 11, record head 13, playhead 15", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  S.buffers[1].seconds = 0
  for cell = 1, 16 do assert_equal(positions.grid_level(1, cell, 16), 0, "an empty slot: cell " .. cell) end
  S.buffers[1].seconds = 16
  half_peaks(S)
  params:set("v1_loop_length", 0.5); params:set("v1_loop_start", 0.25)
  positions.jump(1, 0.5)  -- inside the loop: the playhead is cell 9
  assert_equal(positions.grid_level(1, 1, 16), 2, "outside: 1 + round(1)")
  assert_equal(positions.grid_level(1, 16, 16), 2)
  assert_equal(positions.grid_level(1, 6, 16), 6, "inside: 4 + round(2)")
  assert_equal(positions.grid_level(1, 9, 16), 15, "the playhead")
  positions.grid_key(1, 1, 7, 16, 1)  -- the press jumps there: the playhead shows on it
  assert_equal(positions.grid_level(1, 7, 16), 15, "the playhead wins over a held key")
  positions.jump(1, 0.5)  -- the head moves on; the key is still down
  assert_equal(positions.grid_level(1, 7, 16), 11, "a held key")
  assert_equal(positions.grid_level(1, 6, 16), 6, "its neighbor is unchanged")
  positions.grid_key(1, 1, 7, 16, 0)
  assert_equal(positions.grid_level(1, 7, 16), 6, "released")
  params:set("v1_source", 1)
  assert_equal(positions.grid_level(1, 6, 16), 0, "a synth voice: dark")
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)

  S.lib.record.state = function(slot)
    if slot ~= 1 then return nil end
    return {number = 1, kind = "playable", phase = "recording", started_at = util.time() - 12, seconds = 16, loop = true}
  end
  assert_equal(positions.grid_level(1, 13, 16), 13, "the record head: 12 s of 16 is cell 13")
  assert_equal(positions.grid_level(1, 12, 16), 6, "no head there")
  positions.jump(1, 12 / 16)
  assert_equal(positions.grid_level(1, 13, 16), 15, "the playhead wins")
  assert_equal(positions.grid_level(3, 1, 16), 15, "a stopped voice shows its start at 15")
  assert_equal(positions.grid_level(3, 5, 16), 6, "and the rest of its whole-slot loop at 4 + round(2)")
end)

test("a stopped voice shows its start position at 15", function()
  local _, S = buffer_voices()
  half_peaks(S)
  params:set("v3_buf_pos", 0.5)
  assert_equal(S.lib.positions.grid_level(3, 9, 16), 15)
  assert_equal(S.lib.positions.grid_level(3, 8, 16), 6, "inside the whole-slot loop: 4 + round(2)")
end)

test("strip keys recall, store with store held, hold the scan and restore the whole loop", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  positions.strip_key(1, 1, 2, 1)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "bookmark 2 recalled at once")
  positions.strip_key(1, 1, 2, 0)
  assert_equal(positions.strip_level(1, 2), 10, "the last recalled")
  assert_equal(positions.strip_level(1, 3), 6, "an unrecalled bookmark")

  params:set("v1_buf_scan", 0.1); S.lib.playheads.reset(1)
  context.clock.run_for(1)
  local playhead = S.lib.playheads.position(1)
  assert_equal(positions.strip_level(1, "store"), 4)
  positions.strip_key(1, 1, "store", 1)
  assert_equal(positions.strip_level(1, "store"), 15, "store held")
  positions.strip_key(1, 1, 3, 1)
  assert_near(params:get("v1_bookmark_3"), playhead, 1e-6, "a bookmark key with store held stores the playhead")
  assert_equal(positions.strip_level(1, 3), 15, "pressed with store held")
  assert_equal(positions.last_recalled(1), 2, "storing recalls nothing")
  positions.strip_key(1, 1, 3, 0); positions.strip_key(1, 1, "store", 0)
  assert_equal(positions.strip_level(1, "store"), 4)
  assert_equal(positions.strip_level(1, 3), 6)

  context.clear_engine_calls()
  assert_equal(positions.strip_level(1, "hold"), 4)
  positions.strip_key(1, 1, "hold", 1)
  assert_equal(last_grain(context, "scanHold", 0), 1, "hold down")
  assert_equal(positions.strip_level(1, "hold"), 15)
  positions.strip_key(1, 1, "hold", 0)
  assert_equal(last_grain(context, "scanHold", 0), 0, "hold up")
  assert_equal(positions.strip_level(1, "hold"), 4)

  assert_equal(positions.strip_level(1, "whole"), 15, "the whole slot")
  params:set("v1_loop_length", 0.5)
  assert_equal(positions.strip_level(1, "whole"), 4, "a smaller loop")
  local pos_before = params:get("v1_buf_pos")
  context.clear_engine_calls()
  positions.strip_key(1, 1, "whole", 1)
  local start, length = loop_of(1)
  assert_near(start, 0, 1e-9); assert_near(length, 1, 1e-9)
  assert_equal(positions.strip_level(1, "whole"), 15)
  assert_equal(params:get("v1_buf_pos"), pos_before, "no jump")
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "and no reset")
end)

test("randomize, mutation and the faders leave bookmarks and friction alone", function()
  local _, S = buffer_voices()
  params:set("scrub_friction", 30)
  for voice_idx = 1, S.constants.NUM_VOICES do
    for n = 1, 4 do params:set("v" .. voice_idx .. "_bookmark_" .. n, 0.1 * n) end
  end
  params:set("mutation_probability", 1); params:set("mutation_amount", 1)
  math.randomseed(11)
  for voice_idx = 1, S.constants.NUM_VOICES do randomize_voice(voice_idx) end
  for _ = 1, 20 do gentle_mutate() end
  for voice_idx = 1, S.constants.NUM_VOICES do
    for n = 1, 4 do
      assert_near(params:get("v" .. voice_idx .. "_bookmark_" .. n), 0.1 * n, 1e-9, "voice " .. voice_idx .. " bookmark " .. n)
    end
    for _, param_id in ipairs(fader_param_ids(voice_idx)) do
      assert_true(not param_id:find("bookmark", 1, true) and param_id ~= "scrub_friction", param_id .. " is no fader")
    end
  end
  assert_equal(params:get("scrub_friction"), 30)
end)

-- #557: a press of ALT+K2 on VOICE's bookmarks section draws the four
-- bookmarks in order (the record's randomize), each set before the next is
-- drawn: four uniform 0-1 positions in ascending order, so bookmark n
-- averages n / 5 (the n-th lowest of four uniform draws)
test("the bookmarks' randomize draws four uniform positions in ascending order (#557)", function()
  local _, S = buffer_voices()
  local record
  for _, each in ipairs(S.registry.voice_params) do
    if each.name == "bookmarks" then record = each end
  end
  local keys = {}
  for key in pairs(record.randomize) do keys[#keys + 1] = key end
  table.sort(keys)
  assert_equal(table.concat(keys, ","), "bookmark_1,bookmark_2,bookmark_3,bookmark_4", "the drawn keys")
  math.randomseed(29)
  local sums, trials = { 0, 0, 0, 0 }, 400
  local lowest, highest = math.huge, -math.huge
  for _ = 1, trials do
    local previous = 0
    for n = 1, 4 do
      local value = record.randomize["bookmark_" .. n](2)
      assert_true(value >= previous and value <= 1, "bookmark " .. n .. " " .. value .. " at or above the one before, at most 1")
      params:set("v2_bookmark_" .. n, value)
      sums[n] = sums[n] + value
      previous = value
      lowest, highest = math.min(lowest, value), math.max(highest, value)
    end
  end
  for n = 1, 4 do
    assert_near(sums[n] / trials, n / 5, 0.03, "bookmark " .. n .. " averages " .. n .. "/5")
  end
  assert_true(lowest < 0.01 and highest > 0.99, "the four span 0-1")
end)

test("the bookmark rows show on VOICE for a buffer voice only", function()
  local _, S = buffer_voices()
  local function outline(voice_idx)
    local ids = {}
    for _, row in ipairs(voice_page_rows(voice_idx)) do table.insert(ids, row.param_id or row.section) end
    return table.concat(ids, " ")
  end
  assert_true(outline(1):find("v1_bookmark_1 v1_bookmark_2 v1_bookmark_3 v1_bookmark_4", 1, true), "a buffer voice")
  params:set("v1_source", 1)
  assert_true(not outline(1):find("bookmark", 1, true), "a synth voice")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  assert_true(not outline(1):find("bookmark", 1, true), "an input voice")
end)

-- A stand-in for a connected grid of a size (what layout_of reads)
local function with_grid(S, cols, rows)
  S.grids[1] = {cols = cols, rows = rows}
end

test("a strip hold's release sends one scanHold 0 for the voice it names and holds", function()
  local context, S = buffer_voices()
  with_grid(S, 16, 8)
  local positions = S.lib.positions
  positions.strip_key(1, 1, "hold", 1)
  context.clear_engine_calls()
  positions.strip_key(1, 1, "hold", 0)
  assert_equal(#grain_calls(context, "scanHold"), 1, "voice 1 once")
  S.grids[1] = nil
end)

test("on a 256 a strip hold's release ends only its own voice", function()
  local _, S = buffer_voices()
  with_grid(S, 16, 16)
  local positions = S.lib.positions
  positions.strip_key(1, 1, "hold", 1); positions.strip_key(1, 2, "hold", 1)
  positions.strip_key(1, 1, "hold", 0)
  assert_equal(positions.scan_held(1), false)
  assert_equal(positions.scan_held(2), true, "voice 2's key is still down")
  positions.strip_key(1, 2, "hold", 0)
  assert_equal(positions.scan_held(2), false)
  S.grids[1] = nil
end)

test("on a 256 a strip store's release ends only its own voice: voice 2's next bookmark press stores", function()
  local context, S = buffer_voices()
  with_grid(S, 16, 16)
  local positions = S.lib.positions
  positions.strip_key(1, 1, "store", 1); positions.strip_key(1, 2, "store", 1)
  positions.strip_key(1, 1, "store", 0)
  params:set("v2_bookmark_3", 0.9)
  params:set("v2_buf_pos", 0.2)
  context.clear_engine_calls()
  positions.strip_key(1, 2, 3, 1)
  assert_true(math.abs(params:get("v2_bookmark_3") - 0.9) > 1e-6, "the press stored the playhead")
  assert_equal(positions.last_recalled(2), nil, "and recalled nothing")
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "no jump was sent")
  S.grids[1] = nil
end)

-- #239: store is a port's, per voice; each grid's store LED shows only
-- its own key
test("the store LED is the port's own", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  context.grid.plug(1, 16, 16)
  context.grid.plug(2, 16, 8)
  S.lib.grid_core.set_page(2, 4)
  positions.strip_key(2, 1, "store", 1)
  assert_equal(positions.strip_level(1, "store", 2), 15, "the 128h's store key is down")
  assert_equal(positions.strip_level(1, "store", 1), 4, "the 256's is not")
  assert_equal(positions.strip_level(1, "store"), 15, "with no port: any port's")
  positions.strip_key(2, 1, 3, 1)
  assert_equal(positions.strip_level(1, 3, 2), 15, "the bookmark stored on the 128h")
  assert_equal(positions.strip_level(1, 3, 1), 6, "the 256 shows it unpressed")
  positions.strip_key(2, 1, 3, 0); positions.strip_key(2, 1, "store", 0)
  assert_equal(positions.strip_level(1, "store", 2), 4)
end)

test("a 128h's store ends when the grid shows another page", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  context.grid.plug(1, 16, 8)
  S.lib.grid_core.set_page(1, 4)
  positions.strip_key(1, 1, "store", 1, 1, pane_still(S, 1, 1))
  S.lib.grid_core.set_page(1, 1)
  context.clock.run_for(0.1)
  assert_equal(positions.strip_level(1, "store", 1), 4, "store ended with the page")
  S.lib.grid_core.set_page(1, 4)
  params:set("v1_bookmark_3", 0.9)
  positions.strip_key(1, 1, 3, 1)
  assert_near(params:get("v1_buf_pos"), 0.9, 1e-9, "the next press recalls")
end)

-- #238: the scan hold has a set of holders per voice (each grid port, the
-- arc), and the hold LED shows the hold itself
test("the hold LED follows the scan hold, not the key", function()
  local context, S = buffer_voices()
  with_grid(S, 16, 8)
  local positions = S.lib.positions
  assert_true(S.voices[1].active, "voice 1 runs")
  positions.strip_key(1, 1, "hold", 1)
  assert_equal(positions.strip_level(1, "hold"), 15, "held")
  assert_equal(last_grain(context, "scanHold", 0), 1, "scanHold 1 sent")
  toggle_voice(1); toggle_voice(1)
  assert_true(S.voices[1].active, "voice 1 runs again")
  assert_equal(positions.strip_level(1, "hold"), 4, "the restart dropped the hold: the key goes dim")
  assert_equal(last_grain(context, "scanHold", 0), 0, "the voice sync sent scanHold 0")
  assert_equal(positions.scan_held(1), false)
  local count = #grain_calls(context, "scanHold")
  positions.strip_key(1, 1, "hold", 0)
  assert_equal(#grain_calls(context, "scanHold"), count, "the release sends nothing more")
  S.grids[1] = nil
end)

test("a synth voice's hold key stays dim and holds nothing", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v3_source", 1)
  context.clear_engine_calls()
  positions.strip_key(1, 3, "hold", 1)
  assert_equal(positions.strip_level(3, "hold"), 0, "dark (#445)")
  assert_equal(#grain_calls(context, "scanHold"), 0, "no scanHold")
  assert_equal(positions.scan_held(3), false)
  positions.strip_key(1, 3, "hold", 0)
end)

test("two holders: the scan stays held until the last lets go", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  positions.hold_scan(1, true, "grid:1")
  positions.hold_scan(1, true, "arc")
  assert_equal(#grain_calls(context, "scanHold"), 1, "one scanHold in all")
  assert_equal(last_grain(context, "scanHold", 0), 1, "scanHold 1")
  positions.hold_scan(1, false, "arc")
  assert_equal(#grain_calls(context, "scanHold"), 1, "the first release sends no scanHold 0")
  assert_equal(positions.scan_held(1), true, "still held by the grid")
  positions.hold_scan(1, false, "grid:1")
  assert_equal(#grain_calls(context, "scanHold"), 2, "the last release sends one")
  assert_equal(last_grain(context, "scanHold", 0), 0, "scanHold 0")
  assert_equal(positions.scan_held(1), false)
end)

test("a release by a port that holds nothing changes nothing", function()
  local context, S = buffer_voices()
  with_grid(S, 16, 16)
  local positions = S.lib.positions
  positions.hold_scan(1, true, "arc")
  positions.strip_key(1, 1, "hold", 0)
  assert_equal(positions.scan_held(1), true, "the arc still holds")
  assert_equal(last_grain(context, "scanHold", 0), 1, "no scanHold 0")
  S.grids[1] = nil
end)

test("a hold let go after the voice left its buffer is forgotten", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  toggle_voice(1)
  assert_true(not S.voices[1].active, "voice 1 stopped")
  positions.strip_key(1, 1, "hold", 1)
  assert_equal(positions.scan_held(1), true, "a stopped buffer voice is held")
  params:set("v1_source", 1)
  positions.strip_key(1, 1, "hold", 0)
  assert_equal(positions.scan_held(1), false, "the release forgets it")
end)

-- The final review's item 5: an invariant only reads, and a grid that left
-- gets no layout state back from the module that forgets its keys
test("checking the invariants after a grid left leaves no port state behind", function()
  local context, S = buffer_voices()
  local positions, grid_core = S.lib.positions, S.lib.grid_core
  context.grid.plug(1, 16, 8)
  grid_core.set_page(1, 4)
  positions.strip_key(1, 1, "store", 1)  -- the port's record exists
  context.grid.unplug(1)
  assert_equal(grid_core.existing_port_state(1), nil, "the unplug emptied the port's state")
  assert_equal(#h.check_invariants(), 0, "every invariant holds")
  assert_equal(grid_core.existing_port_state(1), nil, "checking the invariants created none")
  context.clock.run_for(0.2)
  assert_equal(positions.strip_level(1, "store"), positions.LEVELS.key_up, "the tick ended the gone grid's store")
  assert_equal(grid_core.existing_port_state(1), nil, "nor did the tick that forgot the record")
end)

test("cleanup and an unplugged grid release their holds", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  context.clear_engine_calls()
  positions.strip_key(1, 1, "hold", 1)
  positions.hold_scan(1, true, "arc")
  context.grid.unplug(1)
  context.clock.run_for(0.1)
  assert_equal(positions.scan_held(1), true, "the arc still holds")
  assert_equal(positions.strip_level(1, "hold"), 15, "and the LED shows it")
  cleanup()
  assert_equal(positions.scan_held(1), false, "cleanup releases every holder")
  local releases = 0
  for _, each in ipairs(grain_calls(context, "scanHold")) do
    if each.voice == 0 and each.value == 0 then releases = releases + 1 end
  end
  assert_equal(releases, 1, "exactly one scanHold 0 for voice 0")
end)

test("a row's levels are rebuilt when the slot's peaks change (#398)", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  local calls = 0
  local real_bins = S.lib.waveforms.bins
  S.lib.waveforms.bins = function(...) calls = calls + 1; return real_bins(...) end
  local current = {}
  for index = 1, S.constants.WAVEFORM_POINTS do current[index] = 0.5 end
  S.lib.waveforms.peaks = function() return current end
  assert_equal(positions.grid_level(1, 5, 16), 6, "inside the whole-slot loop: 4 + round(2)")
  positions.grid_level(1, 6, 16)
  assert_equal(calls, 1, "one build while the peaks table stays")
  local louder = {}
  for index = 1, S.constants.WAVEFORM_POINTS do louder[index] = 1 end
  current = louder
  assert_equal(positions.grid_level(1, 5, 16), 8, "new peaks: 4 + round(4)")
  assert_equal(calls, 2, "one more build")
end)

test("a voice that reads no buffer has a dark strip and stores nothing (#445)", function()
  local _, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v1_source", 1)
  for _, key in ipairs({1, 2, 3, 4, "store", "hold", "whole"}) do
    assert_equal(positions.strip_level(1, key), 0, "synth voice, key " .. tostring(key))
    assert_equal(positions.strip_level(1, key, 1), 0, "with a port, key " .. tostring(key))
  end
  local before = params:get("v1_bookmark_2")
  positions.strip_key(1, 1, "store", 1)
  positions.strip_key(1, 1, 2, 1)
  assert_equal(positions.strip_level(1, "store"), 0, "store held: still dark")
  assert_equal(positions.strip_level(1, 2), 0, "a pressed bookmark lights nothing")
  assert_equal(params:get("v1_bookmark_2"), before, "and the bookmark keeps its value")
  positions.strip_key(1, 1, 2, 0); positions.strip_key(1, 1, "store", 0)
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  assert_equal(positions.strip_level(1, "store"), positions.LEVELS.key_up, "a store that was never recorded is up on a buffer voice")
  assert_equal(positions.strip_level(1, 2), positions.LEVELS.bookmark, "and so is the bookmark")
  params:set("v1_source", S.constants.SOURCE_INPUT)
  assert_equal(positions.strip_level(1, 1), 0, "an input voice: dark too")
end)

test("one glide clock follows a run of turns, and a turn during the glide ends it and waits again (#515)", function()
  local context, S = buffer_voices()
  params:set("scrub_friction", 50)
  local started, real_run = 0, clock.run
  clock.run = function(...) started = started + 1; return real_run(...) end
  fling(context, S, 0.2, 0.5)  -- 50 deltas
  assert_equal(started, 1, "one clock for 50 deltas")
  context.clock.run_for(0.08 + 0.001)
  assert_true(S.lib.positions.scrub_rate(1) > 0.1, "the glide started at the last turns' speed")
  context.clear_engine_calls()
  S.lib.positions.scrub_turned(1)
  assert_equal(S.lib.positions.scrub_rate(1), 0, "a turn ends the glide at once")
  assert_equal(last_grain(context, "scrubRate", 0), 0)
  context.clock.run_for(0.5)
  assert_equal(S.lib.positions.scrub_rate(1), 0, "a lone turn does not restart it")
  fling(context, S, -0.2, 0.3)
  context.clock.run_for(0.08 + 0.001)
  assert_true(S.lib.positions.scrub_rate(1) < -0.1, "the next fling glides at its own speed")
  context.clock.run_for(60)
  assert_equal(S.lib.positions.scrub_rate(1), 0, "and decays to its end")
  fling(context, S, 0.2, 0.2)
  clock.run = real_run
  assert_true(started <= 4, "a few clocks over the whole run, one per fling: " .. started)
end)

-- 3.4 (design §8.9, plan item 12): the grid's position and bookmark keys
-- wait for the beat or bar quantize_actions names; jump, recall_bookmark and
-- a step's bookmark lock (S.lib.bookmarks.recall) never wait
test("a position key and a bookmark key wait for the bar; a step's bookmark lock does not", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  local function run_to_beat(beat)
    context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
  end
  params:set("quantize_actions", 3)  -- bar
  run_to_beat(1.5)
  positions.grid_key(1, 1, 9, 16, 1)
  positions.grid_key(1, 1, 9, 16, 0)
  assert_near(params:get("v1_buf_pos"), 0, 1e-9, "the jump waits")
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "no scan restart yet")
  assert_true(S.lib.quantize.waiting("position1"))
  assert_equal(S.lib.ui_flash.text("header"), "v1 jump at bar")
  run_to_beat(3.98)
  assert_near(params:get("v1_buf_pos"), 0, 1e-9, "beat 3.98: still waits")
  run_to_beat(4.02)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "the jump lands at the bar")
  assert_equal(#grain_calls(context, "t_scanReset"), 1, "one scan restart")

  -- a two-key loop replaces the waiting jump of its first key
  positions.grid_key(1, 1, 5, 16, 1)
  positions.grid_key(1, 1, 9, 16, 1)
  release_all(positions, 16, 1, 9, 5)
  local start, length = loop_of(1)
  assert_near(start, 0, 1e-9, "the loop waits too"); assert_near(length, 1, 1e-9)
  run_to_beat(8.02)
  start, length = loop_of(1)
  assert_near(start, 0.25, 1e-9, "the loop lands at the bar"); assert_near(length, 0.3125, 1e-9)
  assert_near(params:get("v1_buf_pos"), 0, 1e-9, "at the loop's start, not cell 5's jump")
  params:set("v1_loop_start", 0); params:set("v1_loop_length", 1)

  positions.strip_key(1, 1, 2, 1)
  positions.strip_key(1, 1, 2, 0)
  assert_equal(positions.last_recalled(1), nil, "the bookmark recall waits")
  assert_true(S.lib.quantize.waiting("bookmark1"))
  assert_equal(S.lib.ui_flash.text("header"), "v1 bm 2 at bar")
  run_to_beat(12.02)
  assert_equal(positions.last_recalled(1), 2, "recalled at the bar")
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9)

  S.lib.bookmarks.recall(1, 3)
  assert_equal(positions.last_recalled(1), 3, "a step's bookmark lock recalls at once")
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9)
  assert_true(not S.lib.quantize.waiting("bookmark1"), "and schedules nothing")
  positions.recall_bookmark(1, 4)
  assert_equal(positions.last_recalled(1), 4, "recall_bookmark itself is immediate")
  positions.jump(1, 0.1)
  assert_near(params:get("v1_buf_pos"), 0.1, 1e-9, "so is jump")
end)

-- 3.7 (design §10, decision 13): a slice row, on the doubles of 2b, 2a and
-- 2d that test/helpers.lua shares (h.slice_doubles)
local slice_doubles = h.slice_doubles

-- Buffer voices 1-3 on slot 1, which holds `count` slices; voice 1 plays them
local function slice_voices(count)
  local context, S = buffer_voices()
  local doubles = slice_doubles(S, {[1] = count or 20})
  doubles.takes[1] = true
  return context, S, doubles
end

local function row_levels(positions, voice_idx, port)
  local levels = {}
  for cell = 1, 16 do levels[cell] = positions.grid_level(voice_idx, cell, 16, port) end
  return table.concat(levels, " ")
end

local function bank_levels(positions, voice_idx, port)
  local levels = {}
  for n = 1, 4 do levels[n] = positions.strip_level(voice_idx, n, port) end
  return table.concat(levels, " ")
end

local function press(positions, port, voice_idx, cell)
  positions.grid_key(port, voice_idx, cell, 16, 1)
end
local function release(positions, port, voice_idx, cell)
  positions.grid_key(port, voice_idx, cell, 16, 0)
end

test("a voice that plays slices shows 16 slice keys and its strip's bookmark keys as banks", function()
  local _, S = slice_voices(20)
  local positions = S.lib.positions
  assert_equal(positions.slice_row(1), true, "voice 1 plays slices")
  assert_equal(positions.slice_row(2), false, "voice 2 does not")
  assert_equal(positions.bank(1, 1), 1, "bank 1 by default")
  assert_equal(row_levels(positions, 1, 1), "9 9 9 9 9 9 9 9 9 9 9 9 9 9 9 9", "bank 1: slices 1-16")
  assert_equal(bank_levels(positions, 1, 1), "15 4 0 0", "bank 1 shown, bank 2 holds slices")
  positions.strip_key(1, 1, 2, 1); positions.strip_key(1, 1, 2, 0)
  assert_equal(positions.bank(1, 1), 2)
  assert_equal(S.lib.grid_core.port_state(1).positions.bank[1], 2, "kept in the port's state")
  assert_equal(row_levels(positions, 1, 1), "9 9 9 9 0 0 0 0 0 0 0 0 0 0 0 0", "bank 2: slices 17-20")
  assert_equal(bank_levels(positions, 1, 1), "4 15 0 0")
  positions.strip_key(1, 1, 3, 1); positions.strip_key(1, 1, 3, 0)
  assert_equal(positions.bank(1, 1), 2, "a bank with no slices is not picked")
  assert_equal(positions.last_recalled(1), nil, "the bank keys recall no bookmark")
  -- store held: the keys still pick banks, and store nothing
  local bookmark_1 = params:get("v1_bookmark_1")
  positions.strip_key(1, 1, "store", 1)
  assert_equal(positions.strip_level(1, "store", 1), 15, "store as before")
  positions.strip_key(1, 1, 1, 1); positions.strip_key(1, 1, 1, 0)
  positions.strip_key(1, 1, "store", 0)
  assert_equal(positions.bank(1, 1), 1, "bank 1 again")
  assert_equal(params:get("v1_bookmark_1"), bookmark_1, "and no bookmark stored")
  assert_equal(positions.strip_level(1, "hold", 1), 4, "hold as before")
  assert_equal(positions.strip_level(1, "whole", 1), 15, "whole as before")
end)

test("a press plays its slice and the release ends it", function()
  local context, S, doubles = slice_voices(30)
  local positions = S.lib.positions
  positions.strip_key(1, 1, 2, 1); positions.strip_key(1, 1, 2, 0)
  context.clear_engine_calls()
  press(positions, 1, 1, 5)
  assert_equal(#doubles.plays, 1, "one play")
  local play = doubles.plays[1]
  assert_equal(play.voice, 1); assert_equal(play.n, 21, "bank 2, cell 5: (2 - 1) x 16 + 5")
  assert_equal(play.note.owner, "grid"); assert_equal(play.note.key, 1 * 100 + 21); assert_equal(play.note.velocity, 1)
  assert_equal(#doubles.offs, 0, "nothing ends yet")
  release(positions, 1, 1, 5)
  assert_equal(#doubles.offs, 1, "the release ends it")
  assert_equal(doubles.offs[1].voice, 1); assert_equal(doubles.offs[1].owner, "grid"); assert_equal(doubles.offs[1].key, 121)
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "no jump")
  assert_near(params:get("v1_buf_pos"), 0, 1e-9, "buf_pos unchanged")
  -- a cell past the count does nothing
  press(positions, 1, 1, 15); release(positions, 1, 1, 15)
  assert_equal(#doubles.plays, 1, "slice 31 of 30: no play")
  assert_equal(#doubles.offs, 1, "and no off")
  assert_equal(#grain_calls(context, "t_scanReset"), 0, "and no jump")
end)

test("a playing slice is brightest and a held key next", function()
  local _, S, doubles = slice_voices(20)
  local positions = S.lib.positions
  press(positions, 1, 1, 4)
  assert_equal(positions.grid_level(1, 4, 16, 1), 15, "playing")
  doubles.sounding[104] = nil  -- its note ended, the key is still down
  assert_equal(positions.grid_level(1, 4, 16, 1), 11, "held")
  assert_equal(positions.grid_level(1, 4, 16, 2), 9, "another grid does not hold it")
  assert_equal(positions.grid_level(1, 4, 16), 11, "with no port: any grid's key")
  doubles.sounding.other = {voice = 1, n = 7}
  assert_equal(positions.grid_level(1, 7, 16, 1), 15, "a slice another note plays")
  assert_equal(positions.grid_level(1, 7, 16, 2), 15, "on every grid")
  release(positions, 1, 1, 4)
  assert_equal(positions.grid_level(1, 4, 16, 1), 9, "released")
  assert_equal(positions.grid_level(1, 3, 16, 1), 9, "a slice that exists")
end)

local function run_to_beat(context, beat)
  context.clock.run_for((beat - clock.get_beats()) * clock.get_beat_sec())
end

test("a slice key waits for the beat or bar when the quantizer says so", function()
  local context, S, doubles = slice_voices(20)
  local positions = S.lib.positions
  params:set("quantize_actions", 3)  -- bar
  run_to_beat(context, 1.5)
  press(positions, 1, 1, 2)
  assert_equal(#doubles.plays, 0, "the slice waits")
  assert_true(S.lib.quantize.waiting("position1"), "under the position key")
  assert_equal(S.lib.ui_flash.text("header"), "v1 sl 2 at bar")
  assert_equal(positions.grid_level(1, 2, 16, 1), 11, "held while it waits")
  run_to_beat(context, 4.02)
  assert_equal(#doubles.plays, 1, "it plays at the bar")
  assert_equal(doubles.plays[1].n, 2)
  release(positions, 1, 1, 2)
  assert_equal(#doubles.offs, 1, "the release after it ends it")
  params:set("quantize_actions", 2)  -- beat
  press(positions, 1, 1, 3)
  assert_equal(#doubles.plays, 1, "the beat waits too")
  run_to_beat(context, 5.02)
  assert_equal(#doubles.plays, 2)
  release(positions, 1, 1, 3)
end)

test("a key released before its quantized play takes it back in wrap, and lets it play in one shot", function()
  local context, S, doubles = slice_voices(20)
  local positions = S.lib.positions
  params:set("quantize_actions", 3)  -- bar
  run_to_beat(context, 1.5)
  press(positions, 1, 1, 2); release(positions, 1, 1, 2)
  assert_true(not S.lib.quantize.waiting("position1"), "taken back")
  run_to_beat(context, 4.02)
  assert_equal(#doubles.plays, 0, "nothing plays at the bar")
  assert_equal(#doubles.offs, 0, "and nothing is ended")
  assert_equal(positions.grid_level(1, 2, 16, 1), 9, "nor held")
  doubles.pass = 2  -- one shot, a moving scan: a tap plays at the beat
  run_to_beat(context, 5.5)
  press(positions, 1, 1, 3); release(positions, 1, 1, 3)
  assert_true(S.lib.quantize.waiting("position1"), "still waits")
  run_to_beat(context, 8.02)
  assert_equal(#doubles.plays, 1, "and plays at the bar")
  assert_equal(doubles.plays[1].n, 3)
  assert_equal(#doubles.offs, 1, "its note off follows the play (a one-shot slice note plays on to its end)")
  assert_equal(doubles.offs[1].key, 103)
end)

test("two grids hold their own banks", function()
  local _, S, doubles = slice_voices(20)
  local positions = S.lib.positions
  positions.strip_key(1, 1, 2, 1); positions.strip_key(1, 1, 2, 0)
  assert_equal(positions.bank(1, 1), 2, "grid 1 shows bank 2")
  assert_equal(positions.bank(2, 1), 1, "grid 2 still bank 1")
  assert_equal(positions.grid_level(1, 5, 16, 1), 0, "grid 1's cell 5: slice 21 of 20")
  assert_equal(positions.grid_level(1, 5, 16, 2), 9, "grid 2's: slice 5")
  assert_equal(bank_levels(positions, 1, 1), "4 15 0 0")
  assert_equal(bank_levels(positions, 1, 2), "15 4 0 0")
  press(positions, 2, 1, 5)
  assert_equal(doubles.plays[1].n, 5, "grid 2 plays from its own bank")
  assert_equal(doubles.plays[1].note.key, 205, "its key is the port's")
  press(positions, 1, 1, 1)
  assert_equal(doubles.plays[2].n, 17)
  assert_equal(doubles.plays[2].note.key, 117)
  release(positions, 2, 1, 5); release(positions, 1, 1, 1)
  assert_equal(doubles.offs[1].key, 205); assert_equal(doubles.offs[2].key, 117)
end)

test("a voice with slices off keeps its position cells and bookmarks", function()
  local context, S, doubles = slice_voices(20)
  local positions = S.lib.positions
  doubles.takes[1] = false
  half_peaks(S)
  assert_equal(positions.slice_row(1), false)
  assert_equal(positions.grid_level(1, 1, 16, 1), 15, "the playhead, as before")
  assert_equal(positions.grid_level(1, 5, 16, 1), 6, "a position cell, as before")
  press(positions, 1, 1, 5); release(positions, 1, 1, 5)
  assert_near(params:get("v1_buf_pos"), 0.25, 1e-9, "a press jumps")
  positions.strip_key(1, 1, 3, 1); positions.strip_key(1, 1, 3, 0)
  assert_equal(positions.last_recalled(1), 3, "a strip key recalls its bookmark")
  assert_equal(positions.strip_level(1, 3, 1), 10, "lit as the last recalled")
  assert_equal(#doubles.plays, 0, "no slice played")
  -- the option on, the slot with no slices: positions too
  doubles.takes[1] = true
  doubles.counts[1] = 0
  assert_equal(positions.slice_row(1), false, "no slices: a position row")
  context.clear_engine_calls()
  press(positions, 1, 1, 9); release(positions, 1, 1, 9)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "a press jumps")
  assert_equal(#doubles.plays, 0)
end)

test("the bank returns to 1 when the slot's slices no longer reach it", function()
  local _, S, doubles = slice_voices(40)
  local positions = S.lib.positions
  positions.strip_key(1, 1, 3, 1); positions.strip_key(1, 1, 3, 0)
  assert_equal(positions.bank(1, 1), 3, "bank 3: slices 33-40")
  doubles.counts[1] = 20
  assert_equal(positions.bank(1, 1), 1, "slices 1-20: bank 3 is empty, bank 1 shows")
  assert_equal(bank_levels(positions, 1, 1), "15 4 0 0")
  assert_equal(#doubles.binds, 1, "one listener for the binds")
  for _, listener in ipairs(doubles.binds) do listener(1) end
  doubles.counts[1] = 40
  assert_equal(positions.bank(1, 1), 1, "the bind put it back to 1")
  positions.strip_key(1, 1, 2, 1); positions.strip_key(1, 1, 2, 0)
  for _, listener in ipairs(doubles.binds) do listener(2) end
  assert_equal(positions.bank(1, 1), 2, "a bind of another slot leaves it")
  for _, listener in ipairs(doubles.binds) do listener(1) end
  assert_equal(positions.bank(1, 1), 2, "and so does a bind whose slices still reach it")
  assert_equal(#doubles.binds, 1, "still one listener")
end)

-- 2e's review (the controller's ruling): with no bind, markers deleted
-- below the bank and added back never bring the old pick back once a key
-- has read it
test("a pick the slices no longer reach is forgotten when a key reads it", function()
  local _, S, doubles = slice_voices(40)
  local positions = S.lib.positions
  positions.strip_key(1, 1, 3, 1); positions.strip_key(1, 1, 3, 0)
  doubles.counts[1] = 20  -- markers deleted below bank 3
  press(positions, 1, 1, 2)
  assert_equal(doubles.plays[1].n, 2, "the press plays from bank 1")
  release(positions, 1, 1, 2)
  doubles.counts[1] = 40  -- added back
  assert_equal(positions.bank(1, 1), 1, "the press forgot the pick")

  positions.strip_key(1, 1, 3, 1); positions.strip_key(1, 1, 3, 0)
  doubles.counts[1] = 20
  positions.strip_key(1, 1, 3, 1); positions.strip_key(1, 1, 3, 0)  -- an empty bank: not picked
  doubles.counts[1] = 40
  assert_equal(positions.bank(1, 1), 1, "a bank key's press forgot it too")
end)

test("a held slice key ends when its grid shows another page or leaves", function()
  local context, S, doubles = slice_voices(20)
  context.grid.plug(1, 16, 16)
  S.lib.grid_core.set_page(1, 5)
  local positions = S.lib.positions
  positions.grid_key(1, 1, 2, 16, 1, 1, pane_still(S, 1, 1))
  S.lib.grid_core.set_page(1, 1)
  positions.end_stale_holds()
  assert_equal(#doubles.offs, 1, "the page change ends it")
  assert_equal(doubles.offs[1].key, 102)
  release(positions, 1, 1, 2)
  assert_equal(#doubles.offs, 1, "and its late release ends nothing more")
  S.lib.grid_core.set_page(1, 5)
  press(positions, 1, 1, 3)
  context.grid.unplug(1)
  positions.end_stale_holds()
  assert_equal(#doubles.offs, 2, "an unplug ends it")
  assert_equal(doubles.offs[2].key, 103)
end)


-- The Wave 2 landing: the slice rows read S.lib.slices, S.lib.samples and
-- S.lib.scan at each use and never check they are there, so a missing
-- module fails loudly instead of showing a plain row
test("without the slices, the file's settings or the scan the slice rows fail loudly", function()
  local context, S, doubles = slice_voices(40)
  local positions = S.lib.positions
  local slices, samples, scan = S.lib.slices, S.lib.samples, S.lib.scan
  S.lib.slices = nil
  local ok, err = pcall(positions.slice_row, 1)
  assert_true(not ok and tostring(err):find("slices", 1, true) ~= nil, "no S.lib.slices: an error: " .. tostring(err))
  S.lib.slices = slices
  -- the first bank pick hears the binds
  S.lib.samples = nil
  ok, err = pcall(positions.strip_key, 1, 1, 2, 1)
  assert_true(not ok and tostring(err):find("samples", 1, true) ~= nil, "no S.lib.samples: an error: " .. tostring(err))
  S.lib.samples = samples
  -- a slice key released while its quantized play waits asks the scan
  params:set("quantize_actions", 3)  -- bar
  run_to_beat(context, 1.5)
  press(positions, 1, 1, 3)
  S.lib.scan = nil
  ok, err = pcall(release, positions, 1, 1, 3)
  assert_true(not ok and tostring(err):find("scan", 1, true) ~= nil, "no S.lib.scan: an error: " .. tostring(err))
  S.lib.scan = scan
  assert_equal(#doubles.plays, 0)
end)

end

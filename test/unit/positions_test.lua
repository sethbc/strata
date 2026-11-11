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
  positions.strip_key(1, 1, "hold", 1)
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
  positions.grid_key(1, 1, 5, 16, 1)
  S.lib.grid_core.set_page(1, 1)
  context.clock.run_for(0.1)
  S.lib.grid_core.set_page(1, 5)
  positions.grid_key(1, 1, 9, 16, 1)
  assert_near(params:get("v1_buf_pos"), 0.5, 1e-9, "a jump to cell 9")
  local start, length = loop_of(1)
  assert_near(start, 0, 1e-9, "the loop unchanged"); assert_near(length, 1, 1e-9)
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

test("a position press selects the grid voice on the 128s and the 64, never on the 256", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  local plugged = {[1] = {16, 16}, [2] = {16, 8}, [3] = {8, 16}, [4] = {8, 8}}
  for port, size in pairs(plugged) do context.grid.plug(port, size[1], size[2]) end
  S.grid_voice_select = 6
  positions.grid_key(1, 3, 5, 16, 1); positions.grid_key(1, 3, 5, 16, 0)
  assert_equal(S.grid_voice_select, 6, "the 256 keeps its grid voice")
  local expected = {[2] = 3, [3] = 2, [4] = 1}  -- voices 1-3 read buffers
  for port = 2, 4 do
    S.grid_voice_select = 6
    positions.grid_key(port, expected[port], 5, 16, 1); positions.grid_key(port, expected[port], 5, 16, 0)
    assert_equal(S.grid_voice_select, expected[port], "port " .. port .. " selects the pressed voice")
  end
end)

test("a press on a synth or input voice's row never changes the grid voice, on any layout", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v4_source", 1)
  params:set("v5_source", S.constants.SOURCE_INPUT)
  context.grid.plug(2, 16, 8); context.grid.plug(3, 8, 16); context.grid.plug(4, 8, 8)
  for port = 2, 4 do
    S.grid_voice_select = 6
    positions.grid_key(port, 4, 5, 16, 1); positions.grid_key(port, 4, 5, 16, 0)
    positions.grid_key(port, 5, 5, 16, 1); positions.grid_key(port, 5, 5, 16, 0)
    assert_equal(S.grid_voice_select, 6, "port " .. port .. ": the grid voice stays")
    positions.grid_key(port, 3, 5, 16, 1); positions.grid_key(port, 3, 5, 16, 0)
    assert_equal(S.grid_voice_select, 3, "port " .. port .. ": a buffer voice's row selects it")
  end
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

test("bookmarks default to the quarters, are scene fields that crossfade and migrate from version 3", function()
  local context, S = buffer_voices()
  for voice_idx = 1, S.constants.NUM_VOICES do
    for n, expected in ipairs({0, 0.25, 0.5, 0.75}) do
      assert_near(params:get("v" .. voice_idx .. "_bookmark_" .. n), expected, 1e-9)
    end
  end
  assert_equal(S.constants.SCENE_DATA_VERSION, 4)
  params:set("v1_bookmark_2", 0.75)
  capture_scene(1)
  assert_near(S.scenes[1].data.voices[1].extras.bookmark_2, 0.75, 1e-9, "the scene captures it")
  params:set("v1_bookmark_2", 0.25)
  recall_scene(1, 1)
  context.clock.run_for(0.5)
  local halfway = params:get("v1_bookmark_2")
  assert_true(halfway > 0.3 and halfway < 0.7, "crossfading at 0.5 s, got " .. halfway)
  context.clock.run_for(2)
  assert_near(params:get("v1_bookmark_2"), 0.75, 1e-9, "ends at the scene's value")

  S.scenes[3] = h.deep_copy(S.scenes[1])
  for voice_idx = 1, S.constants.NUM_VOICES do
    for n = 1, 4 do S.scenes[3].data.voices[voice_idx].extras["bookmark_" .. n] = nil end
  end
  migrate_scene(S.scenes[3], 3)
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
    scene.data.voices[1].extras.bookmark_1 = value
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
  assert_near(S.voices[2].extras.bookmark_3, 0.3, 1e-9, "stored too")
end)

test("store_bookmark takes the playhead, or buf_pos mapped into the loop when stopped", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  params:set("v1_buf_pos", 0.25); params:set("v1_buf_scan", 0.1)
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

-- A stand-in for a connected grid of a size (what `selects_grid_voice` reads)
local function with_grid(S, cols, rows)
  S.grids[1] = {cols = cols, rows = rows}
end

test("a strip hold's release ends the hold for the voice it was pressed for, after a grid voice change", function()
  local _, S = buffer_voices()
  with_grid(S, 16, 8)
  local positions = S.lib.positions
  positions.strip_key(1, 1, "hold", 1)
  assert_equal(positions.scan_held(1), true, "voice 1 held")
  positions.strip_key(1, 2, "hold", 0)
  assert_equal(positions.scan_held(1), false, "a release naming voice 2 ends voice 1's hold")
  assert_equal(positions.scan_held(2), false)
  assert_equal(positions.strip_level(1, "hold"), 4)
  S.grids[1] = nil
end)

test("a strip store's release ends store for the voice it was pressed for, after a grid voice change", function()
  local _, S = buffer_voices()
  with_grid(S, 16, 8)
  local positions = S.lib.positions
  positions.strip_key(1, 1, "store", 1)
  assert_equal(positions.strip_level(1, "store"), 15)
  positions.strip_key(1, 2, "store", 0)
  assert_equal(positions.strip_level(1, "store"), 4, "a release naming voice 2 ends voice 1's store")
  params:set("v1_bookmark_3", 0.9)
  positions.strip_key(1, 1, 3, 1)
  assert_near(params:get("v1_buf_pos"), 0.9, 1e-9, "the next press recalls instead of storing")
  S.grids[1] = nil
end)

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

-- #239: on the grids with one strip, store belongs to the port; each
-- grid's store LED shows only its own key
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

test("each grid's redraw lights only its own store key", function()
  local context, S = buffer_voices()
  local full = context.grid.plug(1, 16, 16)
  local wide = context.grid.plug(2, 16, 8)
  S.lib.grid_core.set_page(1, 5)  -- the 256's strips: voice v's on row 8 + v
  S.lib.grid_core.set_page(2, 4)  -- the 128h's strip: store at (13, 6)
  S.grid_voice_select = 1
  S.lib.positions.strip_key(2, 1, "store", 1)
  grid_redraw()
  assert_equal(wide:get_led(13, 6), 15, "the 128h's store key is down")
  assert_equal(full:get_led(6, 9), 4, "the 256's store key for voice 1 is not")
  S.lib.positions.strip_key(2, 1, "store", 0)
  S.lib.positions.strip_key(1, 1, "store", 1)
  grid_redraw()
  assert_equal(full:get_led(6, 9), 15, "the 256's store key for voice 1 is down")
  assert_equal(wide:get_led(13, 6), 4, "the 128h's is not")
  S.lib.positions.strip_key(1, 1, "store", 0)
end)

test("a one-strip grid's store ends when the grid shows another page", function()
  local context, S = buffer_voices()
  local positions = S.lib.positions
  context.grid.plug(1, 16, 8)
  S.lib.grid_core.set_page(1, 4)
  positions.strip_key(1, 1, "store", 1)
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

end

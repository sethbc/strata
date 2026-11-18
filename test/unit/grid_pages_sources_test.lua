-- test/unit/grid_pages_sources_test.lua
-- Grid page 4, sources (lib/grid/pages/sources.lua, design §10.6): line v
-- is voice v; x 1-7 the voices (its own column the synth, pressed again
-- its own output), x 8 the input (pressed again its channel), x 9-16 the
-- slots, on every arrangement (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_sources

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane = h.grid_pane

-- The page's columns, in pane coordinates: voice j at x j, the input at
-- x 8, slot n at x 8 + n
local INPUT_X = 8
local SLOT_X = 8

-- The source a key of line v picks (the voice's own column is its synth)
local function source_of_key(S, voice_idx, x)
  local c = S.constants
  if x == voice_idx then return c.SOURCE_SYNTH end
  if x < INPUT_X then return c.SOURCE_VOICE_FIRST + x - 1 end
  if x == INPUT_X then return c.SOURCE_INPUT end
  return c.SOURCE_SYNTH + x - SLOT_X
end

local function source(voice_idx) return params:get("v" .. voice_idx .. "_source") end
local function channel(voice_idx) return params:get("v" .. voice_idx .. "_input_channel") end

-- What key x of line v shows, worked out here from the design's table:
-- the own column 15 on the synth, its own output 15 / 6 by the blink's
-- phase (0.5 s each), else 4; another voice's 15 read, else 4 running
-- and 2 stopped; the input 15 / 11 / 7 by its channel, else 4; a slot 15
-- read, 2 free and 4 holding audio
local function expected_level(S, voice_idx, x)
  local c = S.constants
  local read = source(voice_idx)
  if x == voice_idx then
    if read == c.SOURCE_SYNTH then return 15 end
    if read == c.SOURCE_VOICE_FIRST + voice_idx - 1 then
      return math.floor(util.time() * 2) % 2 == 0 and 15 or 6
    end
    return 4
  end
  if x < INPUT_X then
    if read == c.SOURCE_VOICE_FIRST + x - 1 then return 15 end
    return S.voices[x].active and 4 or 2
  end
  if x == INPUT_X then
    if read ~= c.SOURCE_INPUT then return 4 end
    return ({15, 11, 7})[channel(voice_idx)]
  end
  if read == c.SOURCE_SYNTH + x - SLOT_X then return 15 end
  return S.lib.buffers.is_free(x - SLOT_X) and 2 or 4
end

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

local function assert_page_lights(S, pane, label)
  local first, last = shown_columns(pane)
  for voice_idx = 1, S.constants.NUM_VOICES do
    for x = first, last do
      assert_equal(pane.led(x, voice_idx), expected_level(S, voice_idx, x),
        label .. ": line " .. voice_idx .. " key " .. x)
    end
  end
end

-- Each arrangement (or those that show every key of `needs`, {x, y}
-- pairs) on a fresh load, its pane on the sources page
local function each_arrangement(body, needs)
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = grid_pane(context, arrangement)
    local shown = true
    for _, key in ipairs(needs or {}) do shown = shown and pane.shows(key[1], key[2]) end
    if shown then
      pane.show(S.constants.GRID_PAGES.sources)
      body(context, S, pane, arrangement)
    end
  end
end

local function pattern_sum(S)
  local sum = 0
  for voice_idx = 1, S.constants.NUM_VOICES do
    for step = 1, S.constants.PATTERN_LENGTH do sum = sum + S.patterns[voice_idx][step] end
  end
  return sum
end

local function last_grain_source(context)
  local calls = context.calls_named("setGrainSource")
  local call = calls[#calls]
  return call and (call.args[1] .. " " .. call.args[2]) or nil
end

test("the sources page is registered at its index", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.sources]
  assert_true(record ~= nil, "a record at page 4")
  assert_equal(record.name, "sources")
  assert_equal(S.lib.grid_pages_sources.record, record, "the module keeps its record")
  assert_true(record.signature ~= nil, "it has a signature (the blink and the channels)")
  assert_equal(record.faders, nil, "and no fader lines")
end)

-- Moved (0e's hand-on list for 2c): the sources parts of the 256's "grid
-- page 4 buffer rows record, clear and set sources with LED feedback" and
-- "grid page 4 buffer LEDs: row 1 state, row 2, source rows, and non-grid
-- changes", the 128h's "128h page 4 sets sources and records and clears
-- slots" and "128h page 4 LEDs come from source_level, record_level and
-- CLEAR_LEVEL", and the 128v's "128v sources page", in pane coordinates
test("sources set and light", function()
  each_arrangement(function(context, S, pane, arrangement)
    load_buffer(2, "/tmp/a.wav")                                    -- slot 2 holds audio
    params:set("record_duration", 2); params:set("buf6_record", 1)  -- slot 6 records
    params:set("v1_source", S.constants.SOURCE_SYNTH + 2)           -- voice 1 on slot 2
    params:set("v4_source", S.constants.SOURCE_SYNTH + 8)           -- voice 4 on an empty slot 8
    assert_page_lights(S, pane, arrangement)
    if pane.shows(SLOT_X + 8, 4) then
      assert_equal(pane.led(SLOT_X + 8, 4), 15, arrangement .. ": the selected empty slot lights 15")
      assert_equal(pane.led(SLOT_X + 8, 3), 2, arrangement .. ": and 2 on another line")
      assert_equal(pane.led(SLOT_X + 2, 3), 4, arrangement .. ": slot 2 holds audio: 4")
    end
    -- every shown key of line 3 but its own: the source it names, alone lit
    local first, last = shown_columns(pane)
    local steps = pattern_sum(S)
    for x = first, last do
      if x ~= 3 then
        context.clear_engine_calls()
        pane.tap(x, 3)
        local wanted = source_of_key(S, 3, x)
        assert_equal(source(3), wanted, arrangement .. ": line 3 key " .. x)
        assert_equal(last_grain_source(context), "2 " .. (wanted - 1), arrangement .. ": the param's switch, voice 3 stopped")
        assert_equal(pane.led(x, 3), 15, arrangement .. ": lit")
        for other = first, last do
          if other ~= x then assert_true(pane.led(other, 3) < 15, arrangement .. ": one lit key a line, not " .. other) end
        end
      end
    end
    assert_equal(pattern_sum(S), steps, arrangement .. ": source keys never toggle steps")
    -- a source set off the grid (the screen, a MIDI map, PARAMETERS) shows at once
    params:set("v5_source", S.constants.SOURCE_INPUT)
    assert_page_lights(S, pane, arrangement .. " after a source set elsewhere")
  end)
end)

test("the own column cycles synth, own output, synth", function()
  each_arrangement(function(context, S, pane, arrangement)
    local own = S.constants.SOURCE_VOICE_FIRST + 3 - 1
    context.set_time(100)  -- the blink's phase 0
    grid_redraw()
    assert_equal(pane.led(3, 3), 15, arrangement .. ": the synth lit")
    pane.tap(3, 3)
    assert_equal(source(3), own, arrangement .. ": pressed again: its own output")
    assert_true(voice_uses_voice(3) and voice_source_voice(3) == 3, arrangement .. ": voice 3 reads itself")
    assert_equal(last_grain_source(context), "2 " .. (own - 1), arrangement .. ": through the param's switch")
    assert_equal(pane.led(3, 3), 15, arrangement .. ": blinks: 15 in the first half second")
    context.set_time(100.5)
    grid_redraw()
    assert_equal(pane.led(3, 3), 6, arrangement .. ": 6 in the second")
    context.set_time(101)
    grid_redraw()
    assert_equal(pane.led(3, 3), 15, arrangement .. ": 15 again")
    pane.tap(3, 3)
    assert_equal(source(3), S.constants.SOURCE_SYNTH, arrangement .. ": again: the synth")
    assert_equal(pane.led(3, 3), 15, arrangement .. ": lit, steady")
    -- from any other source the own column is the synth
    params:set("v3_source", S.constants.SOURCE_SYNTH + 1)
    assert_equal(pane.led(3, 3), 4, arrangement .. ": off the synth: 4")
    pane.tap(3, 3)
    assert_equal(source(3), S.constants.SOURCE_SYNTH, arrangement .. ": a slot's voice: the synth")
    params:set("v3_source", S.constants.SOURCE_VOICE_FIRST)
    pane.tap(3, 3)
    assert_equal(source(3), S.constants.SOURCE_SYNTH, arrangement .. ": another voice's reader: the synth")
  end, {{3, 3}})
end)

test("another column reads that voice", function()
  each_arrangement(function(_, S, pane, arrangement)
    assert_true(not S.voices[5].active, arrangement .. ": voice 5 stopped")
    assert_equal(pane.led(5, 2), 2, arrangement .. ": a stopped voice's key: 2")
    pane.tap(5, 2)
    assert_equal(source(2), S.constants.SOURCE_VOICE_FIRST + 5 - 1, arrangement .. ": voice 2 reads voice 5")
    assert_equal(voice_source_voice(2), 5)
    assert_equal(pane.led(5, 2), 15, arrangement .. ": lit")
    assert_equal(pane.led(2, 2), 4, arrangement .. ": its own column is off the synth")
    assert_equal(pane.led(5, 1), 2, arrangement .. ": line 1's key of voice 5: stopped")
    toggle_voice(5)
    assert_equal(pane.led(5, 1), 4, arrangement .. ": voice 5 started: 4 at once")
    assert_equal(pane.led(5, 2), 15, arrangement .. ": the read key stays 15")
    toggle_voice(5)
    assert_equal(pane.led(5, 1), 2, arrangement .. ": stopped again: 2")
    pane.tap(5, 2)
    assert_equal(source(2), S.constants.SOURCE_VOICE_FIRST + 5 - 1, arrangement .. ": pressed again it stays")
  end, {{2, 1}, {5, 1}})
end)

test("in steps the channel while selected", function()
  each_arrangement(function(_, S, pane, arrangement)
    assert_equal(pane.led(INPUT_X, 4), 4, arrangement .. ": not the input: 4")
    pane.tap(INPUT_X, 4)
    assert_equal(source(4), S.constants.SOURCE_INPUT, arrangement .. ": the input")
    assert_equal(channel(4), 1, arrangement .. ": stereo kept")
    assert_equal(pane.led(INPUT_X, 4), 15, arrangement .. ": stereo 15")
    pane.tap(INPUT_X, 4)
    assert_equal(channel(4), 2, arrangement .. ": pressed again: left")
    assert_equal(pane.led(INPUT_X, 4), 11, arrangement .. ": left 11")
    pane.tap(INPUT_X, 4)
    assert_equal(channel(4), 3, arrangement .. ": right")
    assert_equal(pane.led(INPUT_X, 4), 7, arrangement .. ": right 7")
    pane.tap(INPUT_X, 4)
    assert_equal(channel(4), 1, arrangement .. ": stereo again")
    assert_equal(source(4), S.constants.SOURCE_INPUT, arrangement .. ": still the input")
    -- the channel is kept across a switch away and back
    pane.tap(INPUT_X, 4); pane.tap(INPUT_X, 4)
    pane.tap(4, 4)
    assert_equal(source(4), S.constants.SOURCE_SYNTH, arrangement .. ": the synth")
    assert_equal(pane.led(INPUT_X, 4), 4, arrangement .. ": the input key 4")
    pane.tap(INPUT_X, 4)
    assert_equal(channel(4), 3, arrangement .. ": back on the input, right kept")
    assert_equal(pane.led(INPUT_X, 4), 7)
    -- a channel set off the grid (VOICE, PARAMETERS) shows within a drift tick
    drift_update()
    params:set("v4_input_channel", 2)
    drift_update()
    assert_equal(pane.led(INPUT_X, 4), 11, arrangement .. ": left, set elsewhere")
  end, {{INPUT_X, 4}})
end)

test("a slot holding audio is brighter than a free one", function()
  each_arrangement(function(context, S, pane, arrangement)
    load_buffer(3, "/tmp/a.wav")
    context.polls.fire("bufferState", context.polls.buffer_state_value(3, 1, 12.5))
    assert_true(not S.lib.buffers.is_free(3) and S.lib.buffers.is_free(4), arrangement .. ": slot 3 holds audio, 4 is free")
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(SLOT_X + 3, voice_idx), 4, arrangement .. ": slot 3 on line " .. voice_idx)
      assert_equal(pane.led(SLOT_X + 4, voice_idx), 2, arrangement .. ": slot 4 on line " .. voice_idx)
    end
    pane.tap(SLOT_X + 3, 6)
    assert_equal(source(6), S.constants.SOURCE_SYNTH + 3, arrangement .. ": voice 6 reads slot 3")
    assert_equal(pane.led(SLOT_X + 3, 6), 15, arrangement .. ": lit")
  end, {{SLOT_X + 3, 1}, {SLOT_X + 4, 1}})
end)

test("the blink redraws within a drift tick only while a voice reads itself", function()
  each_arrangement(function(context, S, pane, arrangement)
    local t = 200
    context.set_time(t)
    drift_update()  -- the first look
    local before = pane.device.refresh_count
    for _ = 1, 8 do
      t = t + 0.25
      context.set_time(t)
      drift_update()
    end
    assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": no voice reads itself: idle ticks repaint nothing")
    params:set("v6_source", S.constants.SOURCE_VOICE_FIRST + 6 - 1)
    drift_update()
    local shows = pane.shows(6, 6)
    for _ = 1, 4 do
      local phase = math.floor(t * 2) % 2
      before = pane.device.refresh_count
      t = t + 0.5
      context.set_time(t)
      drift_update()
      assert_true(pane.device.refresh_count > before, arrangement .. ": a phase change redraws within a tick")
      if shows then
        assert_equal(pane.led(6, 6), phase == 0 and 6 or 15, arrangement .. ": the key follows the phase")
      end
      before = pane.device.refresh_count
      drift_update()
      assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": the same phase repaints nothing")
    end
    params:set("v6_source", S.constants.SOURCE_SYNTH)
    drift_update()
    before = pane.device.refresh_count
    for _ = 1, 8 do
      t = t + 0.25
      context.set_time(t)
      drift_update()
    end
    assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": back on the synth: idle again")
  end)
end)

-- Unmentioned case (the brief's): a slot cleared while a voice reads it
test("a cleared slot's key goes to 2 at once and the voice's key stays lit at 15", function()
  each_arrangement(function(context, S, pane, arrangement)
    load_buffer(5, "/tmp/a.wav")
    context.polls.fire("bufferState", context.polls.buffer_state_value(5, 1, 12.5))
    pane.tap(SLOT_X + 5, 1)
    assert_equal(source(1), S.constants.SOURCE_SYNTH + 5, arrangement .. ": voice 1 reads slot 5")
    assert_equal(pane.led(SLOT_X + 5, 2), 4, arrangement .. ": slot 5 holds audio")
    clear_buffer(5)
    assert_equal(pane.led(SLOT_X + 5, 2), 2, arrangement .. ": cleared: 2 at once")
    assert_equal(pane.led(SLOT_X + 5, 1), 15, arrangement .. ": voice 1's key stays 15")
    assert_equal(source(1), S.constants.SOURCE_SYNTH + 5, arrangement .. ": and its source")
  end, {{SLOT_X + 5, 1}})
end)

test("a 64's left half holds the voices and the input, its right half the slots", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = grid_pane(context, "64 left")
  pane.show(S.constants.GRID_PAGES.sources, 1, 1)
  for x = 1, INPUT_X do assert_true(pane.shows(x, 1), "the left half shows key " .. x) end
  assert_true(not pane.shows(SLOT_X + 1, 1), "and no slot")
  pane.tap(2, 1)
  assert_equal(source(1), S.constants.SOURCE_VOICE_FIRST + 1, "left: line 1 key 2 reads voice 2")
  pane.tap(INPUT_X, 7)
  assert_equal(source(7), S.constants.SOURCE_INPUT, "left: line 7 key 8 the input")
  assert_page_lights(S, pane, "64 left")
  pane.show(S.constants.GRID_PAGES.sources, 1, 2)
  for x = SLOT_X + 1, 16 do assert_true(pane.shows(x, 1), "the right half shows key " .. x) end
  assert_true(not pane.shows(INPUT_X, 1), "and not the input")
  pane.tap(SLOT_X + 1, 1)
  assert_equal(source(1), S.constants.SOURCE_SYNTH + 1, "right: line 1 key 9 reads slot 1")
  pane.tap(16, 7)
  assert_equal(source(7), S.constants.SOURCE_SYNTH + 8, "right: line 7 key 16 reads slot 8")
  assert_page_lights(S, pane, "64 right")
end)

test("a source a scene recall sets shows at once", function()
  each_arrangement(function(_, S, pane, arrangement)
    params:set("v3_source", S.constants.SOURCE_SYNTH + 7)
    S.lib.scenes.save(1)
    params:set("v3_source", S.constants.SOURCE_SYNTH)
    assert_equal(pane.led(SLOT_X + 7, 3), 2, arrangement .. ": on the synth")
    recall_scene(1, 0)
    assert_equal(source(3), S.constants.SOURCE_SYNTH + 7, arrangement .. ": the scene's slot 7")
    assert_equal(pane.led(SLOT_X + 7, 3), 15, arrangement .. ": lit")
  end, {{SLOT_X + 7, 3}})
end)

test("keys off the page's lines and columns do nothing, and no grid raises nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.sources]
  local fake = {port = 1, index = 1, page = S.constants.GRID_PAGES.sources, side = 1, width = 16, offset = 0,
    shows = function() return true end, state = function() return {} end}
  local before = {}
  for voice_idx = 1, S.constants.NUM_VOICES do before[voice_idx] = source(voice_idx) end
  for _, key in ipairs({{0, 1}, {17, 1}, {1, 0}, {1, 8}, {1.5, 1}, {"1", 1}, {1, nil}}) do
    record.press(fake, key[1], key[2], 1)
  end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(source(voice_idx), before[voice_idx], "voice " .. voice_idx .. " keeps its source")
  end
  local lit = {}
  record.redraw(fake, function(x, y) lit[#lit + 1] = x .. "," .. y end)
  for _, key in ipairs(lit) do
    local x, y = key:match("^(%d+),(%d+)$")
    x, y = tonumber(x), tonumber(y)
    assert_true(x >= 1 and x <= 16 and y >= 1 and y <= S.constants.NUM_VOICES, "drawn in the pane: " .. key)
  end
  assert_equal(#lit, 16 * S.constants.NUM_VOICES, "every key of every line drawn")
  -- no grid: a source change, the blink and the drift tick raise nothing
  params:set("v2_source", S.constants.SOURCE_VOICE_FIRST + 1)
  drift_update()
  assert_equal(S.lib.grid_pane.signature(), nil, "no pane: no signature")
end)

end

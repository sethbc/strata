-- test/unit/grid_pages_voices_test.lua
-- Grid page 6, voices (lib/grid/pages/voices.lua, design §10.8): line v
-- is voice v; x 1-8 MU SO LK FZ CL RN PC VC, x 9-16 the voice's level
-- (v<v>_amp) as a fader line of eight keys, on every arrangement
-- (h.grid_pane)
-- Run alone: lua test/run.lua grid_pages_voices

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local grid_pane, deep_copy, show_page = h.grid_pane, h.deep_copy, h.show_page

-- The page's keys, in pane coordinates (the design's table)
local KEY = {mute = 1, solo = 2, lock = 3, freeze = 4, clear = 5, randomize = 6, pattern_copy = 7, voice_copy = 8,
  level_first = 9, level_keys = 8}

local function mute(voice_idx) return params:get("v" .. voice_idx .. "_mute") end
local function solo(voice_idx) return params:get("v" .. voice_idx .. "_solo") end
local function frozen(voice_idx) return params:get("v" .. voice_idx .. "_freeze") end

local function voices_pane(context, arrangement, opts)
  local S = local_value("S")
  local pane = grid_pane(context, arrangement, opts)
  pane.show(S.constants.GRID_PAGES.voices)
  return pane
end

-- Each arrangement (or those that show every key of `needs`, {x, y}
-- pairs) on a fresh load, its pane on the voices page
local function each_arrangement(body, needs)
  for _, arrangement in ipairs(h.GRID_ARRANGEMENTS) do
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    local pane = voices_pane(context, arrangement)
    local shown = true
    for _, key in ipairs(needs or {}) do shown = shown and pane.shows(key[1], key[2]) end
    if shown then body(context, S, pane, arrangement) end
  end
end

-- The pane x of key k (1 the minimum) of a voice's level line: on the
-- 128v it runs up (x 16 is its bottom key)
local function level_x(pane, k)
  if pane.arrangement == "128v" then return KEY.level_first + KEY.level_keys - k end
  return KEY.level_first + k - 1
end

local function pattern_of(S, voice_idx)
  local steps = {}
  for step = 1, S.constants.PATTERN_LENGTH do steps[step] = S.patterns[voice_idx][step] end
  return steps
end

local function assert_pattern(S, voice_idx, steps, label)
  for step = 1, S.constants.PATTERN_LENGTH do
    assert_equal(S.patterns[voice_idx][step], steps[step], label .. ": voice " .. voice_idx .. " step " .. step)
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

-- The calls of S.lib.voice_presets.copy, as "from to" (the real copy runs)
local function count_copies(S)
  local calls = {}
  local real_copy = S.lib.voice_presets.copy
  S.lib.voice_presets.copy = function(from_voice, to_voice)
    calls[#calls + 1] = from_voice .. " " .. to_voice
    return real_copy(from_voice, to_voice)
  end
  return calls
end

-- VOICE on voice_idx, the cursor on the first row of its grain section,
-- and a quick ALT+K2 there
local function alt_k2_on_voice(S, voice_idx)
  show_page("VOICE")
  S.selected_voice = voice_idx
  for index, row in ipairs(voice_page_rows(voice_idx)) do
    if row.section == "grain" and row.selectable ~= false then
      S.lib.pages_voice.place_cursor(index)
      break
    end
  end
  key(1, 1); key(2, 1); key(2, 0); key(1, 0)
end

test("the voices page is registered at its index", function()
  load_strata()
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.voices]
  assert_true(record ~= nil, "a record at page 6")
  assert_equal(record.name, "voices")
  assert_equal(S.lib.grid_pages_voices.record, record, "the module keeps its record")
  assert_true(record.signature ~= nil, "it has a signature")
  assert_true(record.faders ~= nil, "and fader lines (the levels)")
end)

-- Moved (0e's hand-on list): the 256's "page 1's row 9 columns 5-11 mute
-- a voice on a tap and solo it on a hold", re-specified: two keys
test("mute and solo are two keys", function()
  each_arrangement(function(context, S, pane, arrangement)
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.mute, voice_idx), 4, arrangement .. ": voice " .. voice_idx .. " not muted: 4")
      assert_equal(pane.led(KEY.solo, voice_idx), 4, arrangement .. ": voice " .. voice_idx .. " not soloed: 4")
    end
    pane.press(KEY.mute, 1, 1)
    assert_equal(mute(1), 1, arrangement .. ": MU mutes voice 1 at its press")
    pane.press(KEY.mute, 1, 0)
    assert_equal(mute(1), 1, arrangement .. ": the release does nothing")
    assert_equal(solo(1), 0, arrangement .. ": and solos nothing")
    assert_equal(pane.led(KEY.mute, 1), 15, arrangement .. ": muted: 15")
    pane.tap(KEY.solo, 3)
    assert_equal(solo(3), 1, arrangement .. ": SO solos voice 3")
    assert_equal(mute(3), 0, arrangement .. ": and mutes nothing")
    assert_equal(pane.led(KEY.solo, 3), 15, arrangement .. ": soloed: 15")
    assert_equal(pane.led(KEY.mute, 3), 4, arrangement .. ": its mute key stays 4")
    assert_true(S.lib.voice_mix.silenced(2), arrangement .. ": voice 2 silenced by the solo")
    assert_equal(pane.led(KEY.mute, 2), 4, arrangement .. ": but not muted: its mute key 4")
    pane.tap(KEY.mute, 3)
    assert_equal(mute(3), 1, arrangement .. ": a soloed voice mutes")
    assert_equal(pane.led(KEY.solo, 3), 15, arrangement .. ": and stays soloed")
    pane.tap(KEY.mute, 3); pane.tap(KEY.solo, 3); pane.tap(KEY.mute, 1)
    assert_equal(mute(1) + mute(3) + solo(3), 0, arrangement .. ": second presses take each back")
    -- a mute or solo set elsewhere (VOICE, a scene, MIDI) shows at once
    params:set("v5_mute", 1); params:set("v6_solo", 1)
    assert_equal(pane.led(KEY.mute, 5), 15, arrangement .. ": a mute set elsewhere")
    assert_equal(pane.led(KEY.solo, 6), 15, arrangement .. ": a solo set elsewhere")
    -- a controller mapped to the params hears the keys (#538)
    local controller = context.midi.plug(1)
    norns.pmap.data["v7_mute"] = {dev = 1, cc = 30, ch = 1, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1, echo = true, value = 0}
    norns.pmap.data["v7_solo"] = {dev = 1, cc = 31, ch = 1, in_lo = 0, in_hi = 127, out_lo = 0, out_hi = 1, echo = true, value = 0}
    pane.tap(KEY.mute, 7); pane.tap(KEY.solo, 7)
    assert_equal(cc_echoes(controller, 30), "127", arrangement .. ": MU through set_binary_param")
    assert_equal(cc_echoes(controller, 31), "127", arrangement .. ": SO through set_binary_param")
    norns.pmap.data["v7_mute"] = nil; norns.pmap.data["v7_solo"] = nil
  end, {{KEY.mute, 1}, {KEY.solo, 1}})
end)

test("MU and the 256's lower strip's mute keys are one action in two places", function()
  local context = load_strata(); finish_startup(context)
  local pane = voices_pane(context, "256 bottom")
  local strip_mute = 9  -- the lower strip: T- T+ P1-P7, then M1-M7 at x 10-16
  pane.tap(KEY.mute, 4)
  assert_equal(pane.led(strip_mute + 4, 8), 15, "MU's mute lights M4")
  pane.tap(strip_mute + 4, 8)
  assert_equal(mute(4), 0, "M4 unmutes")
  assert_equal(pane.led(KEY.mute, 4), 4, "and MU shows it")
end)

-- Moved: the 256's "row 16 columns 1-7 lock voices", its "grid LEDs
-- follow non-grid state changes (I9)" lock part, the 128h's "128h page
-- 2: ... lock" lock part and the 128v's "128v: the faders page's column
-- 7 locks and unlocks voices 1-7"
test("locks", function()
  each_arrangement(function(_, S, pane, arrangement)
    local steps = {}
    for voice_idx = 1, S.constants.NUM_VOICES do steps[voice_idx] = pattern_of(S, voice_idx) end
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.lock, voice_idx), 2, arrangement .. ": voice " .. voice_idx .. " unlocked: 2")
      pane.tap(KEY.lock, voice_idx)
      assert_true(S.locked[voice_idx], arrangement .. ": LK locks voice " .. voice_idx)
      assert_equal(pane.led(KEY.lock, voice_idx), 12, arrangement .. ": locked: 12")
    end
    pane.tap(KEY.lock, 3)
    assert_true(not S.locked[3], arrangement .. ": a second press unlocks")
    assert_equal(pane.led(KEY.lock, 3), 2, arrangement)
    assert_equal(frozen(3), 0, arrangement .. ": the lock is no freeze")
    -- a lock from anywhere (MAIN's K3, the arc, MIDI) goes through toggle_lock
    toggle_lock(3)
    assert_equal(pane.led(KEY.lock, 3), 12, arrangement .. ": a lock set elsewhere shows at once")
    toggle_lock(3)
    assert_equal(pane.led(KEY.lock, 3), 2, arrangement)
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_pattern(S, voice_idx, steps[voice_idx], arrangement .. ": no lock key toggles a step")
    end
  end, {{KEY.lock, 1}})
end)

-- Moved: the 256's "256 page 4 column 12 toggles freeze per voice with LED
-- feedback", the 128h's "128h page 4 column 12 toggles freeze" and the
-- 128v's "128v row 14 toggles freeze"
test("FZ toggles freeze per voice with LED feedback", function()
  each_arrangement(function(_, S, pane, arrangement)
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.freeze, voice_idx), 3, arrangement .. ": voice " .. voice_idx .. " not frozen: 3")
      pane.tap(KEY.freeze, voice_idx)
      assert_equal(frozen(voice_idx), 1, arrangement .. ": FZ freezes voice " .. voice_idx)
      assert_true(S.lib.freeze.is_frozen(voice_idx), arrangement)
      assert_equal(pane.led(KEY.freeze, voice_idx), 15, arrangement .. ": frozen: 15")
      assert_equal(params:get("v" .. voice_idx .. "_source"), S.constants.SOURCE_SYNTH, arrangement .. ": the source is left alone")
    end
    pane.tap(KEY.freeze, 4)
    assert_equal(frozen(4), 0, arrangement .. ": a second press unfreezes")
    assert_equal(pane.led(KEY.freeze, 4), 3, arrangement)
    params:set("v4_freeze", 1)
    assert_equal(pane.led(KEY.freeze, 4), 15, arrangement .. ": a freeze set elsewhere shows at once")
    assert_true(not S.locked[1], arrangement .. ": freeze is not lock")
  end, {{KEY.freeze, 1}})
end)

-- Moved: the 256's "the 256's freeze keys wait for the beat while
-- quantize_actions is on", the 128h's and 128v's "a freeze key waits for
-- the beat and a step key toggles on release" (their freeze parts)
test("freeze waits for the beat", function()
  each_arrangement(function(context, S, pane, arrangement)
    params:set("quantize_actions", 2)  -- beat
    context.clock.run_for(0.25)        -- half a beat in, at 120 BPM
    pane.tap(KEY.freeze, 2)
    assert_equal(frozen(2), 0, arrangement .. ": FZ waits")
    assert_equal(S.lib.ui_flash.text("header"), "v2 frz at beat", arrangement .. ": and says so")
    assert_equal(pane.led(KEY.freeze, 2), 3, arrangement .. ": the key shows the state, not the wait")
    pane.tap(KEY.freeze, 5)
    context.clock.run_for(0.1)
    pane.tap(KEY.freeze, 5)  -- a second press while it waits takes it back (#625)
    context.clock.run_for(0.2)
    assert_equal(frozen(2), 1, arrangement .. ": at the beat: voice 2 frozen")
    assert_equal(pane.led(KEY.freeze, 2), 15, arrangement .. ": and the key shows it")
    assert_equal(frozen(5), 0, arrangement .. ": voice 5's toggle was taken back")
  end, {{KEY.freeze, 1}})
end)

-- #852: the grids' half-second hold is named for what it holds (a
-- recorder's clear, CL and RN), not 3.7's scene save
test("CL and RN hold for GRID_HOLD.action_hold_seconds, the grids' half-second hold", function()
  load_strata()
  local S = local_value("S")
  local GRID_HOLD = S.constants.GRID_HOLD
  assert_equal(GRID_HOLD.action_hold_seconds, 0.5, "the hold is half a second")
  assert_equal(GRID_HOLD.scene_save_seconds, nil, "the old name is gone")
  assert_equal(S.lib.grid_pages_voices.VOICES_PAGE.hold_seconds, GRID_HOLD.action_hold_seconds, "CL and RN read it")
end)

-- Moved: the 256's "256 row 15: clear and randomize light at 2 and act
-- only once held half a second (#443)"
test("clear and randomize act only after 0.5 s", function()
  each_arrangement(function(context, S, pane, arrangement)
    S.patterns[3][1], S.patterns[3][5] = 15, 9
    assert_equal(pane.led(KEY.clear, 3), 2, arrangement .. ": CL at 2")
    assert_equal(pane.led(KEY.randomize, 3), 2, arrangement .. ": RN at 2")
    pane.tap(KEY.clear, 3)
    assert_equal(S.patterns[3][1], 15, arrangement .. ": a tap on CL clears nothing")
    pane.press(KEY.clear, 3, 1)
    assert_equal(pane.led(KEY.clear, 3), 15, arrangement .. ": lit 15 while the hold is pending")
    context.clock.run_for(0.4)
    pane.press(KEY.clear, 3, 0)
    assert_equal(S.patterns[3][1], 15, arrangement .. ": released at 0.4 s: nothing cleared")
    assert_equal(pane.led(KEY.clear, 3), 2, arrangement .. ": the release puts it back at 2")
    local real_request_redraw, screen_requests = request_redraw, 0
    request_redraw = function() screen_requests = screen_requests + 1; real_request_redraw() end
    pane.press(KEY.clear, 3, 1)
    local requests_at_press = screen_requests
    context.clock.run_for(0.4)
    assert_equal(screen_requests, requests_at_press, arrangement .. ": no screen redraw while the hold is pending")
    local refreshes = pane.device.refresh_count
    context.clock.run_for(0.11)
    request_redraw = real_request_redraw
    assert_equal(S.patterns[3][1], 0, arrangement .. ": held 0.5 s: voice 3's pattern is cleared")
    assert_equal(S.patterns[3][5], 0, arrangement)
    assert_true(screen_requests > requests_at_press, arrangement .. ": the screen (SEQ) is asked to show it")
    assert_true(pane.device.refresh_count > refreshes, arrangement .. ": the grids are redrawn")
    assert_equal(pane.led(KEY.clear, 3), 2, arrangement .. ": the key is back at 2 once it has acted")
    pane.press(KEY.clear, 3, 0)
    -- RN randomizes voice 3, once held
    local randomized = {}
    local real_randomize = randomize_pattern
    randomize_pattern = function(voice_idx) table.insert(randomized, voice_idx); real_randomize(voice_idx) end
    pane.tap(KEY.randomize, 3)
    assert_equal(#randomized, 0, arrangement .. ": a tap on RN randomizes nothing")
    pane.press(KEY.randomize, 3, 1)
    assert_equal(pane.led(KEY.randomize, 3), 15, arrangement .. ": lit 15 while pending")
    context.clock.run_for(0.51)
    assert_equal(table.concat(randomized, " "), "3", arrangement .. ": held 0.5 s: voice 3's pattern is randomized")
    assert_equal(pane.led(KEY.randomize, 3), 2, arrangement)
    pane.press(KEY.randomize, 3, 0)
    assert_equal(#randomized, 1, arrangement .. ": the release does nothing more")
    randomize_pattern = real_randomize
  end, {{KEY.clear, 1}, {KEY.randomize, 1}})
end)

-- New, and the solo part of grid_core_test's "a page change cancels the
-- port's pending holds" (0e's hand-on): solo is a press now, so the holds
-- a page change cancels are CL's and RN's; another pane's or another
-- grid's page change leaves them alone
test("CL held across a page change clears nothing", function()
  each_arrangement(function(context, S, pane, arrangement)
    local pages = S.constants.GRID_PAGES
    S.patterns[2][3], S.patterns[4][7] = 15, 6
    local before = pattern_of(S, 4)
    pane.press(KEY.clear, 2, 1)
    pane.show(pages.patterns)
    context.clock.run_for(0.6)
    pane.press(KEY.clear, 2, 0)
    assert_equal(S.patterns[2][3], 15, arrangement .. ": the clear held through a page change cleared nothing")
    pane.show(pages.voices)
    local real_randomize, randomized = randomize_pattern, 0
    randomize_pattern = function(voice_idx) randomized = randomized + 1; real_randomize(voice_idx) end
    pane.press(KEY.randomize, 4, 1)
    pane.show(pages.sources)
    context.clock.run_for(0.6)
    pane.press(KEY.randomize, 4, 0)
    randomize_pattern = real_randomize
    assert_equal(randomized, 0, arrangement .. ": nor did RN randomize")
    assert_pattern(S, 4, before, arrangement)
  end, {{KEY.clear, 1}})
end)

test("another pane's or grid's page change leaves a CL hold to act", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local top = voices_pane(context, "256 top")
  local bottom = voices_pane(context, "256 bottom")
  local other = voices_pane(context, "128h", {port = 2})
  S.patterns[2][3] = 15
  top.press(KEY.clear, 2, 1)
  bottom.show(pages.patterns)
  other.show(pages.scenes)
  context.clock.run_for(0.6)
  top.press(KEY.clear, 2, 0)
  assert_equal(S.patterns[2][3], 0, "the bottom pane's and grid 2's page changes: the top's CL clears")
  -- the same page on both panes: each pane's CL is its own key
  bottom.show(pages.voices)
  S.patterns[5][1] = 15
  bottom.press(KEY.clear, 5, 1)
  assert_equal(bottom.led(KEY.clear, 5), 15, "the bottom's CL pending")
  assert_equal(top.led(KEY.clear, 5), 2, "the top's is not")
  top.show(pages.patterns)
  context.clock.run_for(0.6)
  bottom.press(KEY.clear, 5, 0)
  assert_equal(S.patterns[5][1], 0, "the top's page change leaves the bottom's CL to act")
end)

-- Moved and re-specified: the 256's "row 16 copies a pattern and pastes it
-- onto another voice" and "pasting onto the copied voice changes nothing"
-- (now a press on the copied voice drops the copy)
test("copy and paste a pattern; the copied voice's key drops the copy", function()
  each_arrangement(function(_, S, pane, arrangement)
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.pattern_copy, voice_idx), 2, arrangement .. ": PC " .. voice_idx .. " at 2 with no copy")
    end
    S.patterns[1][1], S.patterns[1][4], S.patterns[1][9] = 15, 7, 1
    local copied = pattern_of(S, 1)
    pane.tap(KEY.pattern_copy, 1)
    local state = S.lib.grid_core.port_state(pane.port).pages.voices
    assert_equal(state.patterns.voice, 1, arrangement .. ": pane.state().patterns names voice 1")
    assert_equal(pane.led(KEY.pattern_copy, 1), 15, arrangement .. ": the copied voice's key lights")
    for voice_idx = 2, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.pattern_copy, voice_idx), 4, arrangement .. ": a paste target shows at 4")
    end
    -- the copy is a snapshot: a later edit of voice 1 does not change it
    S.patterns[1][16] = 15
    pane.tap(KEY.pattern_copy, 3)
    assert_pattern(S, 3, copied, arrangement .. ": pasted")
    assert_true(S.patterns[3] ~= S.patterns[1], arrangement .. ": the paste copies the levels, not the table")
    assert_equal(S.patterns[2][1], 0, arrangement .. ": voice 2 untouched")
    assert_equal(pane.led(KEY.pattern_copy, 1), 15, arrangement .. ": the copy stays")
    -- pasting into a voice and then editing it leaves the copy alone
    S.patterns[3][4] = 0
    pane.tap(KEY.pattern_copy, 7)
    assert_equal(S.patterns[7][4], 7, arrangement .. ": a second paste keeps the copy's own levels")
    -- the copied voice's key drops the copy and changes its pattern in no way
    S.patterns[1][5] = 9
    local own = pattern_of(S, 1)
    pane.tap(KEY.pattern_copy, 1)
    assert_pattern(S, 1, own, arrangement .. ": the copied voice keeps its own pattern")
    assert_equal(state.patterns, nil, arrangement .. ": the copy is dropped")
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.pattern_copy, voice_idx), 2, arrangement .. ": PC " .. voice_idx .. " back to 2")
    end
    -- with no copy a key copies again
    pane.tap(KEY.pattern_copy, 2)
    assert_equal(state.patterns.voice, 2, arrangement .. ": PC copies voice 2")
  end, {{KEY.pattern_copy, 1}})
end)

-- Moved: the 256's "a paste ends the step-level gesture of the voice it
-- lands on"
test("a paste ends the pasted voice's step gestures", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local steps = grid_pane(context, "256 top")
  steps.show(pages.patterns)
  local voices = voices_pane(context, "256 bottom")
  local small = grid_pane(context, "128h", {port = 2})
  small.show(pages.patterns)
  S.patterns[1][5], S.patterns[1][6] = 3, 0
  local copied = pattern_of(S, 1)
  voices.tap(KEY.pattern_copy, 1)  -- copy voice 1
  steps.press(5, 3, 1)  -- hold voice 3 step 5 (it toggles at its release)
  small.press(6, 3, 1)  -- and step 6 on the 16x8
  steps.press(6, 2, 1)  -- hold voice 2 step 6: no paste lands there
  voices.tap(KEY.pattern_copy, 3)  -- paste onto voice 3
  assert_equal(S.patterns[3][5], copied[5], "the paste set step 5")
  -- a second key on voice 3's line toggles its own step, as with nothing held
  steps.press(12, 3, 1)
  assert_equal(S.patterns[3][5], copied[5], "the held step keeps the pasted level")
  steps.press(12, 3, 0); steps.press(5, 3, 0)
  assert_equal(S.patterns[3][12], 15, "the new key toggles step 12")
  assert_equal(S.patterns[3][5], copied[5], "the held step's release toggles nothing")
  small.press(14, 3, 1)
  assert_equal(S.patterns[3][6], copied[6], "the 16x8's held step keeps the pasted level")
  small.press(14, 3, 0); small.press(6, 3, 0)
  assert_equal(S.patterns[3][14], 15, "and its new key toggles step 14")
  assert_equal(S.patterns[3][6], copied[6], "and its held step's release toggles nothing")
  -- the other voice's gesture still works
  steps.press(16, 2, 1)
  assert_equal(S.patterns[2][6], 15, "voice 2's held step takes key 16's level")
  assert_equal(S.patterns[2][16], 0, "and the level key does not toggle")
  steps.press(16, 2, 0); steps.press(6, 2, 0)
  assert_equal(small.led(6, 3), S.patterns[3][6], "the 16x8 shows the pasted step")
end)

-- Moved: the 256's "the clipboard is per grid, works on pages 2, 3 and 4
-- and goes with the grid" (its per-grid part)
test("the copy is per grid", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local one = voices_pane(context, "128h")
  local two = voices_pane(context, "128h", {port = 2})
  S.patterns[1][2] = 15
  one.tap(KEY.pattern_copy, 1)
  one.tap(KEY.voice_copy, 2)
  assert_equal(two.led(KEY.pattern_copy, 1), 2, "the other grid has no pattern copy")
  assert_equal(two.led(KEY.voice_copy, 2), 2, "nor a voice copy")
  two.tap(KEY.pattern_copy, 3)
  assert_equal(two.led(KEY.pattern_copy, 3), 15, "a key on grid 2 copies there")
  assert_equal(S.patterns[3][2], 0, "and pastes nothing from grid 1's copy")
  assert_equal(one.led(KEY.pattern_copy, 1), 15, "grid 1 keeps its own")
  -- a 256's two panes on the page share their port's copies
  local top = voices_pane(context, "256 top", {port = 3})
  local bottom = voices_pane(context, "256 bottom", {port = 3})
  top.tap(KEY.pattern_copy, 1)
  assert_equal(bottom.led(KEY.pattern_copy, 1), 15, "the bottom pane shows the top's copy")
  bottom.tap(KEY.pattern_copy, 6)
  assert_equal(S.patterns[6][2], 15, "and pastes it")
end)

-- Moved: the same test's "goes with the grid" part (pages 2, 3 and 4
-- become any page change of the pane)
test("a copy survives a page change and goes with the grid", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.GRID_PAGES
  local pane = voices_pane(context, "128h")
  S.patterns[1][2] = 15
  pane.tap(KEY.pattern_copy, 1)
  pane.tap(KEY.voice_copy, 2)
  for _, page in ipairs({pages.patterns, pages.faders, pages.scenes, pages.sources, pages.positions}) do
    pane.show(page)
    pane.show(pages.voices)
    assert_equal(pane.led(KEY.pattern_copy, 1), 15, "page " .. page .. " and back: the pattern copy stays")
    assert_equal(pane.led(KEY.voice_copy, 2), 15, "page " .. page .. " and back: the voice mark stays")
  end
  pane.tap(KEY.pattern_copy, 4)
  assert_equal(S.patterns[4][2], 15, "and pastes")
  context.grid.unplug(1)
  pane = voices_pane(context, "128h")
  assert_equal(pane.led(KEY.pattern_copy, 1), 2, "unplugging forgets the pattern copy")
  assert_equal(pane.led(KEY.voice_copy, 2), 2, "and the voice mark")
  S.patterns[1][2] = 0
  pane.tap(KEY.pattern_copy, 5)
  assert_equal(pane.led(KEY.pattern_copy, 5), 15, "a key copies afresh")
end)

test("VC marks, a second VC loads the sound through voice_presets.copy, the marked key drops it", function()
  each_arrangement(function(_, S, pane, arrangement)
    local calls = count_copies(S)
    params:set("v2_grain_size", 0.31)
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.voice_copy, voice_idx), 2, arrangement .. ": VC " .. voice_idx .. " at 2 with no mark")
    end
    pane.tap(KEY.voice_copy, 2)
    assert_equal(#calls, 0, arrangement .. ": the mark copies nothing")
    local state = S.lib.grid_core.port_state(pane.port).pages.voices
    assert_equal(state.sound.voice, 2, arrangement .. ": pane.state().sound names voice 2")
    assert_equal(pane.led(KEY.voice_copy, 2), 15, arrangement .. ": the marked voice 15")
    assert_equal(pane.led(KEY.voice_copy, 5), 4, arrangement .. ": the others 4")
    -- the sound is read at the paste, not at the mark
    params:set("v2_grain_size", 0.42)
    pane.tap(KEY.voice_copy, 5)
    assert_equal(table.concat(calls, ","), "2 5", arrangement .. ": voice_presets.copy(2, 5)")
    assert_equal(S.voices[5].name, S.voices[2].name, arrangement .. ": voice 5 takes voice 2's type")
    assert_near(S.voices[5].values.grain_size, 0.42, 1e-9, arrangement .. ": and its sound at the paste")
    assert_equal(pane.led(KEY.voice_copy, 2), 15, arrangement .. ": the mark stays")
    pane.tap(KEY.voice_copy, 7)
    assert_equal(table.concat(calls, ","), "2 5,2 7", arrangement .. ": a second paste")
    pane.tap(KEY.voice_copy, 2)
    assert_equal(#calls, 2, arrangement .. ": the marked key copies nothing")
    assert_equal(state.sound, nil, arrangement .. ": it drops the mark")
    for voice_idx = 1, S.constants.NUM_VOICES do
      assert_equal(pane.led(KEY.voice_copy, voice_idx), 2, arrangement .. ": VC " .. voice_idx .. " back to 2")
    end
    pane.tap(KEY.voice_copy, 6)
    assert_equal(state.sound.voice, 6, arrangement .. ": with no mark a key marks again")
  end, {{KEY.voice_copy, 1}})
end)

test("a refused voice copy changes nothing and the mark stays", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = voices_pane(context, "128h")
  local before = deep_copy(S.lib.scenes.capture_voice(3))
  pane.tap(KEY.voice_copy, 2)
  local apply_voice = S.lib.scenes.apply_voice
  S.lib.scenes.apply_voice = function() return false end  -- an apply the scenes refuse
  pane.tap(KEY.voice_copy, 3)
  S.lib.scenes.apply_voice = apply_voice
  assert_equal(S.voices[3].name, before.type, "voice 3 keeps its type")
  assert_equal(pane.led(KEY.voice_copy, 2), 15, "the mark stays")
  assert_equal(pane.led(KEY.voice_copy, 3), 4, "voice 3's key is a target still")
end)

test("ALT+K2 on VOICE undoes a grid voice copy", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = voices_pane(context, "128h")
  local before = deep_copy(S.lib.scenes.capture_voice(5))
  pane.tap(KEY.voice_copy, 2)
  pane.tap(KEY.voice_copy, 5)
  assert_equal(S.voices[5].name, S.voices[2].name, "voice 5 on voice 2's type")
  assert_true(S.voices[5].name ~= before.type, "another type than its own")
  assert_true(S.lib.mutation.undo_for(S.constants.UI_PAGES.index.VOICE, "voice", 5), "the copy's undo is held")
  alt_k2_on_voice(S, 5)
  assert_equal(S.voices[5].name, before.type, "voice 5's own type")
  for key, value in pairs(before.values) do
    assert_near(S.voices[5].values[key], value, 1e-9 * math.max(1, math.abs(value)), key .. " from before")
  end
end)

-- Unmentioned case (the brief's)
test("VC onto a locked voice loads the sound (a lock guards against randomize, not edits)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = voices_pane(context, "128h")
  pane.tap(KEY.lock, 4)
  assert_true(S.locked[4], "voice 4 locked")
  pane.tap(KEY.voice_copy, 2)
  pane.tap(KEY.voice_copy, 4)
  assert_equal(S.voices[4].name, S.voices[2].name, "voice 4 takes voice 2's type")
  assert_true(S.locked[4], "and stays locked")
  assert_equal(pane.led(KEY.lock, 4), 12, "its lock key lit")
end)

-- Fix round 1: a lock guards the voice's sound (its params), not its
-- pattern (docs/notes/lua/mutation.md, as in 3.7), so the pattern keys
-- still act on a locked voice; a change of the lock's reach is a decision
test("RN and CL act on a locked voice's pattern (a lock guards its sound, not its pattern)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = voices_pane(context, "128h")
  pane.tap(KEY.lock, 3)
  assert_true(S.locked[3], "voice 3 locked")
  for step = 1, S.constants.PATTERN_LENGTH do S.patterns[3][step] = 0 end
  local real_random = math.random
  math.random = function(low, high)  -- every step set, at its draw's top
    if low == nil then return 1 end
    return high
  end
  pane.press(KEY.randomize, 3, 1)
  context.clock.run_for(0.51)
  pane.press(KEY.randomize, 3, 0)
  math.random = real_random
  for step = 1, S.constants.PATTERN_LENGTH do
    assert_equal(S.patterns[3][step], S.constants.MAX_STEP_LEVEL, "RN randomized the locked voice's step " .. step)
  end
  pane.press(KEY.clear, 3, 1)
  context.clock.run_for(0.51)
  pane.press(KEY.clear, 3, 0)
  for step = 1, S.constants.PATTERN_LENGTH do
    assert_equal(S.patterns[3][step], 0, "CL cleared the locked voice's step " .. step)
  end
  assert_true(S.locked[3], "and it stays locked")
end)

test("a paste onto a locked voice replaces its pattern", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = voices_pane(context, "128h")
  S.patterns[1][2], S.patterns[1][11] = 15, 6
  S.patterns[4][7] = 9
  local copied = pattern_of(S, 1)
  pane.tap(KEY.lock, 4)
  assert_true(S.locked[4], "voice 4 locked")
  pane.tap(KEY.pattern_copy, 1)
  pane.tap(KEY.pattern_copy, 4)
  assert_pattern(S, 4, copied, "the paste replaced the locked voice's pattern")
  assert_true(S.locked[4], "and it stays locked")
end)

-- Fix round 1: holds are keyed per physical key, so two voices' CL keys
-- held at once each act at their own hold
test("two voices' CL held together each clear at their own hold; an early release cancels that one alone", function()
  each_arrangement(function(context, S, pane, arrangement)
    S.patterns[2][1], S.patterns[5][1], S.patterns[6][1] = 15, 15, 15
    pane.press(KEY.clear, 2, 1)
    context.clock.run_for(0.2)
    pane.press(KEY.clear, 5, 1)
    assert_equal(pane.led(KEY.clear, 2), 15, arrangement .. ": voice 2's CL pending")
    assert_equal(pane.led(KEY.clear, 5), 15, arrangement .. ": and voice 5's")
    context.clock.run_for(0.31)
    assert_equal(S.patterns[2][1], 0, arrangement .. ": voice 2 cleared at its hold")
    assert_equal(S.patterns[5][1], 15, arrangement .. ": voice 5 not yet")
    assert_equal(pane.led(KEY.clear, 5), 15, arrangement .. ": still pending")
    context.clock.run_for(0.2)
    assert_equal(S.patterns[5][1], 0, arrangement .. ": voice 5 cleared at its own")
    pane.press(KEY.clear, 2, 0); pane.press(KEY.clear, 5, 0)
    -- two held, one let go early: only the other acts
    S.patterns[2][1] = 15
    pane.press(KEY.clear, 6, 1)
    pane.press(KEY.clear, 2, 1)
    context.clock.run_for(0.3)
    pane.press(KEY.clear, 6, 0)
    assert_equal(pane.led(KEY.clear, 6), 2, arrangement .. ": voice 6's let go: back to 2")
    assert_equal(pane.led(KEY.clear, 2), 15, arrangement .. ": voice 2's still pending")
    context.clock.run_for(0.3)
    pane.press(KEY.clear, 2, 0)
    assert_equal(S.patterns[6][1], 15, arrangement .. ": voice 6's early release cleared nothing")
    assert_equal(S.patterns[2][1], 0, arrangement .. ": voice 2's hold cleared it")
  end, {{KEY.clear, 1}})
end)

test("lv sets v<v>_amp across eight keys on every arrangement", function()
  each_arrangement(function(_, S, pane, arrangement)
    local steps = pattern_of(S, 2)
    for voice_idx = 1, S.constants.NUM_VOICES do
      local id = "v" .. voice_idx .. "_amp"
      local spec = params:lookup_param(id).controlspec
      pane.tap(level_x(pane, KEY.level_keys), voice_idx)
      assert_near(params:get(id), spec.maxval, 1e-9, arrangement .. ": the top key sets voice " .. voice_idx .. "'s level to its maximum")
      assert_equal(pane.led(level_x(pane, KEY.level_keys), voice_idx), 15, arrangement .. ": lit 15")
      assert_equal(pane.led(level_x(pane, 1), voice_idx), 8, arrangement .. ": the bar at 8")
      pane.tap(level_x(pane, 1), voice_idx)
      assert_near(params:get(id), spec.minval, 1e-9, arrangement .. ": the bottom key its minimum")
      for k = 1, KEY.level_keys do
        pane.tap(level_x(pane, k), voice_idx)
        assert_equal(fader_position(id, KEY.level_keys), k, arrangement .. ": key " .. k .. " of eight")
        assert_equal(pane.led(level_x(pane, k), voice_idx), 15, arrangement .. ": the value at 15")
        if k > 1 then assert_equal(pane.led(level_x(pane, k - 1), voice_idx), 8, arrangement .. ": the bar below") end
        if k < KEY.level_keys then
          assert_equal(pane.led(level_x(pane, k + 1), voice_idx), 0, arrangement .. ": nothing above")
        end
      end
    end
    assert_pattern(S, 2, steps, arrangement .. ": level keys toggle no step")
    -- a level set elsewhere (MAIN, the arc, a scene) shows within a drift tick
    drift_update()
    params:set("v3_amp", params:lookup_param("v3_amp").controlspec.minval)
    drift_update()
    assert_equal(pane.led(level_x(pane, 1), 3), 15, arrangement .. ": a level set elsewhere")
  end, {{KEY.level_first, 1}})
end)

test("a 64's left half holds the eight keys, its right half the level fader", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pane = voices_pane(context, "64 left")
  for x = 1, KEY.voice_copy do assert_true(pane.shows(x, 1), "the left half shows key " .. x) end
  assert_true(not pane.shows(KEY.level_first, 1), "and no level key")
  pane.tap(KEY.mute, 1)
  assert_equal(mute(1), 1, "left: MU mutes voice 1")
  pane.tap(KEY.voice_copy, 7)
  assert_equal(pane.led(KEY.voice_copy, 7), 15, "left: VC marks voice 7")
  pane.show(S.constants.GRID_PAGES.voices, 1, 2)
  for x = KEY.level_first, 16 do assert_true(pane.shows(x, 1), "the right half shows key " .. x) end
  assert_true(not pane.shows(KEY.voice_copy, 1), "and not the eight keys")
  pane.tap(16, 2)
  assert_near(params:get("v2_amp"), params:lookup_param("v2_amp").controlspec.maxval, 1e-9,
    "right: key 16 of line 2 sets voice 2's level to its maximum")
  assert_equal(pane.led(16, 2), 15, "right: lit")
  assert_equal(pane.led(15, 2), 8, "right: the bar")
  pane.tap(KEY.level_first, 7)
  assert_equal(fader_position("v7_amp", KEY.level_keys), 1, "right: key 9 of line 7 its minimum")
  pane.show(S.constants.GRID_PAGES.voices, 1, 1)
  assert_equal(pane.led(KEY.voice_copy, 7), 15, "back on the left: the mark stays")
end)

test("the signature follows mute, solo, lock, freeze and the copies", function()
  each_arrangement(function(_, S, pane, arrangement)
    drift_update()  -- the first look
    local before = pane.device.refresh_count
    for _ = 1, 4 do drift_update() end
    assert_equal(pane.device.refresh_count - before, 0, arrangement .. ": idle ticks repaint nothing")
    -- a lock written without toggle_lock (a scene's lock entry, which
    -- redraws only at the recall's end) shows within a tick
    S.locked[6] = true
    drift_update()
    assert_equal(pane.led(KEY.lock, 6), 12, arrangement .. ": a lock set elsewhere")
    local record = S.registry.grid_pages[S.constants.GRID_PAGES.voices]
    local fake = {port = pane.port, index = 1, page = S.constants.GRID_PAGES.voices,
      state = function() return S.lib.grid_core.port_state(pane.port).pages.voices end}
    local signature = record.signature(fake)
    for _, change in ipairs({
      function() params:set("v1_mute", 1) end,
      function() params:set("v1_solo", 1) end,
      function() toggle_lock(1) end,
      function() params:set("v1_freeze", 1) end,
      function() fake.state().patterns = {voice = 1, steps = {}} end,
      function() fake.state().sound = {voice = 1} end,
    }) do
      change()
      local now = record.signature(fake)
      assert_true(now ~= signature, arrangement .. ": the signature changes")
      signature = now
    end
  end, {{KEY.lock, 1}})
end)

test("a lock and a mute a scene recall sets show at once", function()
  each_arrangement(function(_, S, pane, arrangement)
    toggle_lock(2); params:set("v3_mute", 1)
    S.lib.scenes.save(1)
    toggle_lock(2); params:set("v3_mute", 0)
    assert_equal(pane.led(KEY.lock, 2), 2, arrangement)
    recall_scene(1, 0)
    assert_true(S.locked[2], arrangement .. ": the scene's lock")
    assert_equal(pane.led(KEY.lock, 2), 12, arrangement .. ": lit")
    assert_equal(pane.led(KEY.mute, 3), 15, arrangement .. ": the scene's mute lit")
  end, {{KEY.lock, 1}})
end)

test("keys off the page's lines and columns do nothing, and no grid raises nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.registry.grid_pages[S.constants.GRID_PAGES.voices]
  local state = {}
  local fake = {port = 1, index = 1, page = S.constants.GRID_PAGES.voices, side = 1, width = 16, offset = 0,
    shows = function() return true end, state = function() return state end,
    on_hold = function() error("no hold for a key off the page") end, hold_pending = function() return false end}
  local before = deep_copy(S.patterns)
  for _, key in ipairs({{0, 1}, {9, 1}, {17, 1}, {1, 0}, {1, 8}, {1.5, 1}, {"1", 1}, {1, nil}, {KEY.mute, 2.5}}) do
    record.press(fake, key[1], key[2], 1)
  end
  for voice_idx = 1, S.constants.NUM_VOICES do
    assert_equal(mute(voice_idx), 0, "voice " .. voice_idx .. " not muted")
    assert_true(not S.locked[voice_idx], "voice " .. voice_idx .. " not locked")
    assert_pattern(S, voice_idx, before[voice_idx], "keys off the page")
  end
  assert_equal(next(state), nil, "nothing copied")
  record.press(fake, KEY.mute, 1, 0)
  assert_equal(mute(1), 0, "a release does nothing")
  local lit = {}
  record.redraw(fake, function(x, y) lit[#lit + 1] = x .. "," .. y end)
  for _, key in ipairs(lit) do
    local x, y = key:match("^(%d+),(%d+)$")
    x, y = tonumber(x), tonumber(y)
    assert_true(x >= 1 and x <= KEY.voice_copy and y >= 1 and y <= S.constants.NUM_VOICES, "drawn in the eight keys: " .. key)
  end
  assert_equal(#lit, KEY.voice_copy * S.constants.NUM_VOICES, "every key of every line drawn")
  -- no grid: a mute, a lock and the drift tick raise nothing
  params:set("v2_mute", 1); toggle_lock(2)
  drift_update()
  assert_equal(S.lib.grid_pane.signature(), nil, "no pane: no signature")
end)

end

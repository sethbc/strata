-- test/unit/ui_zones_test.lua
-- The MPE and zones editor (lib/ui/zones.lua, S.lib.ui_zones, 3.5 design
-- 9.3): opened from SETUP's mpe & zones row as a modal owner, it edits the
-- zones' member counts, the bend range and each voice's split zone, and
-- learns a voice's range from the next two notes played
-- Run alone: lua test/run.lua ui_zones

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, next_frame, finish_startup = h.load_strata, h.local_value, h.next_frame, h.finish_startup
local show_page, assert_screen_layout, hint_text, tap = h.show_page, h.assert_screen_layout, h.hint_text, h.tap

-- A script with SETUP shown and the editor open
local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SETUP")
  S.lib.ui_zones.open()
  next_frame(context)
  return context, S, S.lib.ui_zones
end

-- The note tap is the MIDI module's (S.lib.midi_in.set_note_tap(owner, fn)
-- and clear_note_tap(owner), package 2b's, owned since 3.9's #900): this
-- double records what the editor sets and clears, and a test plays notes
-- by calling it
local function tap_double(S)
  local double = { sets = 0 }
  S.lib.midi_in.set_note_tap = function(owner, fn)
    double.sets = double.sets + 1; double.owner, double.fn = owner, fn
    return true
  end
  S.lib.midi_in.clear_note_tap = function(owner)
    if owner ~= double.owner then return false end
    double.owner, double.fn = nil, nil
    return true
  end
  return double
end

-- The texts drawn on the row whose first text is `label`, left to right,
-- joined by spaces, and their entries
local function row(context, label)
  local y
  for _, entry in ipairs(context.screen.texts) do
    if entry.text == label and entry.y > 8 and entry.y < h.HINT_ROW_Y then y = entry.y end
  end
  if not y then return nil end
  local entries = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.y == y then entries[#entries + 1] = entry end
  end
  local function left(entry) return (h.text_span(entry)) end
  table.sort(entries, function(a, b) return left(a) < left(b) end)
  local texts = {}
  for index, entry in ipairs(entries) do texts[index] = entry.text end
  return table.concat(texts, " "), entries
end

local function alt_tap(n) key(1, 1); tap(n); key(1, 0) end

test("the editor edits the member counts, the bend range and each voice's zone and range", function()
  local context, S, zones = loaded()
  assert_true(zones.is_open(), "open")
  assert_equal(row(context, "lower members"), "lower members 15", "the lower zone's members")
  assert_equal(row(context, "upper members"), "upper members 0")
  assert_equal(row(context, "bend range"), "bend range 48 st", "in semitones")
  assert_equal(row(context, "v1"), "v1 lower C-2 G8", "norns' note names: 0 is C-2, 127 is G8")
  assert_equal(row(context, "v2"), "v2 upper C-2 G8")
  assert_equal(row(context, "v3"), "v3 off C-2 G8")
  assert_equal(hint_text(context), "K2:back E3:value", "a row with one value: no K3")
  enc(3, -3)
  assert_equal(params:get("mpe_lower_members"), 12, "E3 on lower members")
  enc(2, 1); enc(3, 2)
  assert_equal(params:get("mpe_upper_members"), 2, "E3 on upper members")
  enc(2, 1); enc(3, -24)
  assert_equal(params:get("mpe_bend_range"), 24, "E3 on the bend range")
  next_frame(context)
  assert_equal(row(context, "bend range"), "bend range 24 st", "drawn at once")
  enc(2, 3)  -- v3
  next_frame(context)
  assert_equal(hint_text(context), "K2:back K3:column E3:value", "a voice row's hint")
  enc(3, 1)
  assert_equal(params:string("v3_zone"), "lower", "E3 on the zone column")
  enc(3, -1)
  assert_equal(params:string("v3_zone"), "off")
  tap(3); enc(3, 12)
  assert_equal(params:get("v3_zone_low"), 12, "K3 to low, E3 +12")
  next_frame(context)
  assert_equal(row(context, "v3"), "v3 off C-1 G8")
  tap(3); enc(3, -67)
  assert_equal(params:get("v3_zone_high"), 60, "K3 to high")
  next_frame(context)
  assert_equal(row(context, "v3"), "v3 off C-1 C3")
  local _, entries = row(context, "v3")
  assert_equal(entries[4].level, 15, "the column under the cursor is bright")
  for index = 1, 3 do assert_equal(entries[index].level, 8, "the rest of the cursor's row: " .. entries[index].text) end
  local _, other = row(context, "v2")
  for _, entry in ipairs(other) do assert_equal(entry.level, 4, "another row is dim: " .. entry.text) end
  tap(3); enc(3, 2)
  assert_equal(params:string("v3_zone"), "upper", "K3 after high wraps to the zone column")
  enc(2, 20)
  next_frame(context)
  assert_true(row(context, "v7") ~= nil, "E2 reaches the last voice")
  enc(3, 1)
  assert_equal(params:string("v7_zone"), "lower", "the column stays the zone's on another voice row")
  enc(2, -30)
  enc(3, -1)
  assert_equal(params:get("mpe_lower_members"), 11, "E2 back to the first row")
  assert_screen_layout(context, "the editor")
end)

test("learn takes the next two notes as a voice's lowest and highest", function()
  local context, S, zones = loaded()
  local double = tap_double(S)
  enc(2, 5)  -- v3
  alt_tap(3)
  local voice, which = zones.learning()
  assert_equal(voice, 3, "ALT+K3 on v3 learns v3")
  assert_equal(which, "low", "waiting for the lowest")
  assert_equal(double.fn, zones.note, "the editor's note is the MIDI module's tap")
  assert_equal(S.lib.ui_flash.text("header"), "learn v3 low", "the header says so")
  next_frame(context)
  assert_equal(row(context, "v3"), "v3 off learn G8", "the column waiting")
  assert_screen_layout(context, "learning v3's low")
  context.clear_engine_calls()
  assert_equal(double.fn(72), true, "the first note is taken")
  assert_equal(params:get("v3_zone_low"), 72, "as the lowest")
  voice, which = zones.learning()
  assert_equal(voice, 3); assert_equal(which, "high", "then the highest")
  assert_equal(S.lib.ui_flash.text("header"), "learn v3 high")
  next_frame(context)
  assert_equal(row(context, "v3"), "v3 off C4 learn")
  assert_equal(double.fn(48), true, "the second note is taken")
  assert_equal(params:get("v3_zone_low"), 48, "a lower second note is the lowest")
  assert_equal(params:get("v3_zone_high"), 72, "and the first the highest")
  assert_equal(zones.learning(), nil, "learn ends")
  assert_equal(double.fn, nil, "and clears the tap")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the notice goes")
  -- the learn consumes both notes (M.note returned true for each, above)
  -- and sends nothing for them; that a consumed MIDI note is silent is the
  -- MIDI module's tap and the release's whole-system test
  assert_equal(#context.engine_calls, 0, "taking the two notes sends no engine command")
  assert_equal(zones.note(60), false, "with no learn waiting a note is not taken")
  -- a higher second note keeps the order
  enc(2, 1)  -- v4
  alt_tap(3)
  assert_equal(double.fn(40), true); assert_equal(double.fn(90), true)
  assert_equal(params:get("v4_zone_low"), 40); assert_equal(params:get("v4_zone_high"), 90)
  -- a first note above the highest raises it
  params:set("v5_zone_high", 30)
  zones.learn(5)
  double.fn(64)
  assert_equal(params:get("v5_zone_low"), 64); assert_equal(params:get("v5_zone_high"), 64)
  double.fn(70)
  assert_equal(params:get("v5_zone_low"), 64); assert_equal(params:get("v5_zone_high"), 70)
  -- not a note, not a voice, not on a voice row
  zones.learn(6)
  for _, bad in ipairs({ -1, 128, 60.5, "60", 0 / 0 }) do
    assert_equal(zones.note(bad), false, "refused: " .. tostring(bad))
  end
  assert_equal(zones.learning(), 6, "still waiting")
  zones.cancel_learn()
  assert_equal(zones.learn(8), false, "no voice 8"); assert_equal(zones.learn(0), false)
  assert_equal(zones.learning(), nil)
  enc(2, -20)  -- lower members
  alt_tap(3)
  assert_equal(zones.learning(), nil, "ALT+K3 learns only on a voice row")
  zones.close()
  assert_equal(zones.learn(2), false, "no learn with the editor closed")
end)

test("a learn ends after 10 s, at K2 and at cleanup, and the note tap is cleared", function()
  local context, S, zones = loaded()
  local double = tap_double(S)
  assert_true(zones.learn(2), "armed")
  assert_equal(S.lib.ui_flash.text("header"), "learn v2 low")
  context.clock.run_for(9.9)
  assert_equal(zones.learning(), 2, "still waiting at 9.9 s")
  double.fn(50)
  context.clock.run_for(0.2)
  assert_equal(zones.learning(), nil, "ended after 10 s")
  assert_equal(S.zones_learn_clock, nil, "with its clock")
  assert_equal(double.fn, nil, "the tap is cleared")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the notice goes")
  assert_equal(params:get("v2_zone_low"), 50, "a note taken before stays")
  assert_equal(params:get("v2_zone_high"), 127)
  -- K2 closes the editor and ends the learn
  zones.learn(2)
  tap(2)
  assert_true(not zones.is_open(), "K2 closes the editor")
  assert_equal(zones.learning(), nil, "and ends the learn")
  assert_equal(double.fn, nil, "the tap is cleared")
  -- so does the cleanup step
  zones.open(); zones.learn(5)
  local step
  for _, record in ipairs(S.registry.cleanup) do
    if record.order == S.constants.CLEANUP_ORDER.zones_learn then step = record.fn end
  end
  assert_true(step ~= nil, "a cleanup step at CLEANUP_ORDER.zones_learn")
  context.clear_engine_calls()
  step()
  assert_equal(zones.learning(), nil, "cleanup ends the learn")
  assert_equal(S.zones_learn_clock, nil, "and cancels its clock")
  assert_equal(double.fn, nil, "and clears the tap")
  assert_equal(#context.engine_calls, 0, "no engine command (norns has freed the engine, #461)")
  zones.close()
end)

-- 3.9 (#900): the tap has an owner, so the scale editor can neither take
-- nor clear the learn's. This tests the API's refusal: no player can open
-- the scale editor over the zones editor (SETUP's keys do not run under a
-- modal owner), so the test calls its open and close directly while a
-- learn waits (the open asks for the tap and is refused, the close's clear
-- names its own owner and does nothing): the learn's real tap takes the
-- next MIDI note
test("the zones learn's tap is not cleared by the scale editor", function()
  local context, S, zones = loaded()
  local midi_in = S.lib.midi_in
  assert_true(zones.learn(3), "a learn waits")
  S.lib.ui_scale_editor.open()
  local after_open = midi_in.note_tap_owner and midi_in.note_tap_owner()
  S.lib.ui_scale_editor.close()
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 1 })
  assert_equal(params:get("v3_zone_low"), 64, "the learn takes the next note")
  assert_equal(next(S.midi_state.held[1]), nil, "which plays nothing: no key is down")
  assert_equal(after_open, zones.ZONES_EDITOR.tap_owner, "the scale editor's open took nothing")
  zones.cancel_learn()
end)

-- 3.9 (#900): a MIDI reset (a channel mode change here) clears the tap and
-- tells its owner: a waiting learn ends, with its notice and its clock
test("a MIDI reset tells the zones learn, which ends", function()
  local context, S, zones = loaded()
  assert_true(zones.learn(2), "a learn waits")
  params:set("midi_channel_mode", 2)
  assert_equal(zones.learning(), nil, "the reset ended the learn")
  assert_equal(S.zones_learn_clock, nil, "and its clock")
  assert_equal(S.lib.ui_flash.text("header"), nil, "the notice goes")
  assert_equal(S.lib.midi_in.note_tap_owner(), nil, "the tap is no one's")
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 1 })
  assert_true(S.midi_state.held[S.selected_voice][1 * 128 + 64], "the next note plays: its key is down")
end)

-- 3.9 (#900): only the editor on top takes notes: under SEQ's step editor
-- a waiting learn's tap takes none (the note plays), and uncovered it does
test("a note while the step editor covers the zones editor is not learned", function()
  local context, S, zones = loaded()
  assert_true(zones.learn(3), "a learn waits")
  assert_true(S.lib.pages_seq.open_step_editor(1, 1, 1), "the step editor opens over it")
  context.midi.send(1, { type = "note_on", note = 64, vel = 100, ch = 1 })
  assert_equal(params:get("v3_zone_low"), 0, "covered: the note is not learned")
  assert_equal(zones.learning(), 3, "the learn still waits")
  assert_true(S.midi_state.held[1][1 * 128 + 64], "the note plays on voice 1, as with no tap: its key is down")
  context.midi.send(1, { type = "note_off", note = 64, vel = 0, ch = 1 })
  S.lib.pages_seq.close_step_editor(1)
  context.midi.send(1, { type = "note_on", note = 65, vel = 100, ch = 1 })
  assert_equal(params:get("v3_zone_low"), 65, "uncovered: the learn takes the note")
  zones.cancel_learn()
end)

-- #626, as MOD's learn: the timeout clock is retired, never canceled, once
-- its resume may be posted, and the old clock ends nothing a newer learn armed
test("a learn ending as its timeout's resume is posted retires the clock, never cancels it (#626)", function()
  local context, S, zones = loaded()
  local double = tap_double(S)
  local function at_timeout(fn)
    context.clock.advance_until(S.zones_learn_clock, fn)
    local errors = context.clock.take_errors()
    assert_equal(#errors, 0, "no resume reaches a canceled clock: " .. table.concat(errors, "; "))
  end
  zones.learn(1)
  at_timeout(function() zones.cancel_learn() end)
  assert_equal(zones.learning(), nil)
  zones.learn(2)
  at_timeout(function() double.fn(40); double.fn(80) end)  -- two notes
  assert_equal(params:get("v2_zone_high"), 80, "the notes learned")
  zones.learn(3)
  at_timeout(function() zones.learn(4) end)  -- a new learn
  assert_equal(zones.learning(), 4, "the new learn still waits")
  assert_true(S.zones_learn_clock ~= nil, "on its own clock")
  context.clock.run_for(10.1)
  assert_equal(zones.learning(), nil, "and times out 10 s after it was armed")
  zones.learn(5)
  local early = S.zones_learn_clock
  zones.cancel_learn()
  assert_equal(clock.threads[early], nil, "an early end cancels the clock")
  zones.learn(5)
  local retired = S.zones_learn_clock
  context.clock.run_for(9.95)
  zones.cancel_learn()
  assert_true(clock.threads[retired] ~= nil, "near its wake the clock is retired, and waits for its wake")
  cleanup()
  assert_equal(clock.threads[retired], nil, "cleanup cancels it")
end)

-- 3.9 (#870): learn's timeout clock is the clock helper's, which retires it
test("the zones learn clock stopped as its wake is posted: no clock error, and nothing more happens", function()
  local context, S, zones = loaded()
  local double = tap_double(S)
  zones.learn(1)
  local id = S.zones_learn_clock
  context.clock.advance_until(id, function()
    zones.learn(2)  -- a new learn ends the old one
    assert_true(S.lib.clocks.retired[id] ~= nil, "the helper retired the old clock: its resume is posted")
  end)
  local errors = context.clock.take_errors()
  assert_equal(#errors, 0, "no resume reaches a canceled clock: " .. table.concat(errors, "; "))
  assert_equal(clock.threads[id], nil, "the old clock ended at its wake")
  assert_equal(S.lib.clocks.retired[id], nil, "and the helper forgot it")
  assert_equal(zones.learning(), 2, "the newer learn still waits")
  assert_true(S.zones_learn_clock ~= nil and S.zones_learn_clock ~= id, "on its own clock")
  assert_equal(double.fn, zones.note, "and its note tap is still set")
end)

test("K2 closes the editor and SETUP shows again; E1 does nothing while it is open", function()
  local context, S, zones = loaded()
  local page = S.ui_page
  enc(1, -3)
  assert_equal(S.ui_page, page, "E1 does nothing")
  assert_true(zones.is_open())
  key(1, 1); tap(2); key(1, 0)
  assert_true(zones.is_open(), "ALT+K2 does nothing")
  tap(2)
  assert_true(not zones.is_open(), "K2 closes it")
  assert_equal(S.lib.ui_modal.top(), nil, "its owner is off the stack")
  next_frame(context)
  assert_true(h.screen_shows(context, "mpe & zones"), "SETUP's rows again")
  zones.close()
  assert_true(not zones.is_open(), "closing a closed editor does nothing")
  zones.open(); zones.open()
  assert_true(zones.is_open(), "a second open does nothing")
  zones.close()
  assert_equal(S.lib.ui_modal.top(), nil, "pushed once")
end)

test("the editor's hints name only the keys that act", function()
  local context, S, zones = loaded()
  local double = tap_double(S)
  assert_equal(hint_text(context), "K2:back E3:value")
  key(1, 1); next_frame(context)
  -- #844: E3 turns with ALT held as without (whole steps), so the hint names it
  assert_equal(hint_text(context), "E2:row E3:value", "ALT on a member count: E2 and E3")
  local members = params:get("mpe_lower_members")
  enc(3, -1)
  assert_equal(params:get("mpe_lower_members"), members - 1, "E3 turns with ALT held")
  enc(3, 1)
  key(1, 0)
  enc(2, 3); next_frame(context)
  assert_equal(hint_text(context), "K2:back K3:column E3:value")
  key(1, 1); next_frame(context)
  assert_equal(hint_text(context), "E2:row K3:learn E3:value", "ALT on a voice row: learn, and E3")
  key(1, 0)
  assert_true(double.sets == 0, "no tap set by a hint")
end)

test("the editor's every state stays inside the layout", function()
  local context, S, zones = loaded()
  tap_double(S)
  -- the widest values: every zone upper, every range C#-2 (the widest name)
  params:set("mpe_bend_range", 96)
  for voice = 1, S.constants.NUM_VOICES do
    params:set("v" .. voice .. "_zone", 3)
    params:set("v" .. voice .. "_zone_low", 1); params:set("v" .. voice .. "_zone_high", 1)
  end
  for row_index = 1, 3 + S.constants.NUM_VOICES do
    enc(2, -20); enc(2, row_index - 1)
    for column = 1, 3 do
      for _, alt in ipairs({ false, true }) do
        if alt then key(1, 1) end
        next_frame(context)
        assert_screen_layout(context, string.format("the editor, row %d, column %d, alt %s", row_index, column, tostring(alt)))
        if alt then key(1, 0) end
      end
      tap(3)
    end
  end
  enc(2, 20)
  zones.learn(S.constants.NUM_VOICES)
  next_frame(context)
  assert_screen_layout(context, "learning v7's low")
  zones.note(1)
  next_frame(context)
  assert_screen_layout(context, "learning v7's high")
  -- SETUP's layout states draw the editor: default, a voice row's high, a learn waiting
  local names = {}
  for _, state in ipairs(S.registry.pages[S.constants.UI_PAGES.index.SETUP].layout_states) do names[state.name] = true end
  for _, name in ipairs({ "mpe & zones editor", "mpe & zones editor, v7's high at its widest",
      "mpe & zones editor, learning v7's low", "mpe & zones editor, learning v7's high" }) do
    assert_true(names[name], "SETUP's layout state: " .. name)
  end
end)

test("K3 on a count row leaves the column alone and changes nothing", function()
  local context, S, zones = loaded()
  local function values()
    local list = {}
    for _, id in ipairs({ "mpe_lower_members", "mpe_upper_members", "mpe_bend_range" }) do list[#list + 1] = params:get(id) end
    for voice = 1, S.constants.NUM_VOICES do
      for _, suffix in ipairs({ "", "_low", "_high" }) do list[#list + 1] = params:get("v" .. voice .. "_zone" .. suffix) end
    end
    return table.concat(list, ",")
  end
  local before = values()
  for row_index = 1, 3 do
    enc(2, -20); enc(2, row_index - 1)
    tap(3); tap(3)
    assert_equal(values(), before, "K3 on count row " .. row_index .. " changes nothing")
    assert_equal(zones.learning(), nil, "and learns nothing")
  end
  enc(2, 1)  -- v1, its column still the zone's
  enc(3, 1)
  assert_equal(params:string("v1_zone"), "upper", "E3 on v1 turns the zone: the column did not move")
  assert_equal(params:get("v1_zone_low"), 0); assert_equal(params:get("v1_zone_high"), 127)
end)

-- The zones editor invariant (S.registry.invariants), called as the harness
-- calls it: nil while it holds, else what is broken
local function zones_invariant(S)
  for _, record in ipairs(S.registry.invariants) do
    if record.name == "zones editor" then return record.fn end
  end
end

test("the editor's invariant holds its own owner and a waiting learn's clock", function()
  local context, S, zones = loaded()
  local invariant = zones_invariant(S)
  assert_true(invariant ~= nil, "the zones editor invariant is registered")
  assert_equal(invariant(), nil, "open, its owner the modal one")
  -- another owner in its owner's place: not the editor's own
  local own = S.lib.ui_modal.top()
  local stranger = { draw = function() end }
  S.lib.ui_modal.pop(own); S.lib.ui_modal.push(stranger)
  assert_true(invariant() ~= nil, "open, but another owner is on the stack: " .. tostring((invariant())))
  S.lib.ui_modal.pop(stranger); S.lib.ui_modal.push(own)
  assert_equal(invariant(), nil, "its own owner back")
  -- a grid's step editor over it (the one owner that can be pushed over it)
  assert_true(S.lib.pages_seq.open_step_editor(1, 1, 1), "the step editor opens over it")
  assert_equal(invariant(), nil, "beneath the step editor")
  S.lib.pages_seq.close_step_editor(1)
  assert_equal(S.lib.ui_modal.top(), own, "the editor on top again")
  assert_equal(invariant(), nil)
  -- a waiting learn: open, the tap set, its clock pending
  tap_double(S)
  zones.learn(3)
  assert_equal(invariant(), nil, "a learn waiting")
  zones.note(60)
  assert_equal(invariant(), nil, "after its first note")
  local learn_clock = S.zones_learn_clock
  clock.cancel(learn_clock)  -- its coroutine gone under it
  assert_true(invariant() ~= nil, "a learn whose clock has ended: " .. tostring((invariant())))
  zones.cancel_learn()
  assert_equal(invariant(), nil, "learn ended")
end)

end

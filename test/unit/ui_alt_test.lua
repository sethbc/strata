-- test/unit/ui_alt_test.lua
-- ALT (K1 held, lib/ui/alt.lua) and its dispatch in strata.lua's key and
-- enc: alt_action, the ALT press and its release, alt_enc falling through to
-- enc, and the norns menu forgetting ALT
-- Run alone: lua test/run.lua ui_alt

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, tap, hint_text = h.show_page, h.tap, h.hint_text

-- Replace the FX page's handlers with ones that log their calls as
-- "<handler> <n>" (and "<handler> <n> <d>" for encoders) into the returned list
local function logging_fx_record(options)
  options = options or {}
  local S = local_value("S")
  local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
  local log = {}
  local function logger(name) return function(n) table.insert(log, name .. " " .. n) end end
  record.key = logger("key")
  record.key_release = logger("key_release")
  record.alt_key = logger("alt_key")
  record.alt_key_release = logger("alt_key_release")
  record.enc = function(n, d) table.insert(log, "enc " .. n .. " " .. d) end
  if options.alt_enc ~= nil then
    record.alt_enc = function(n, d)
      table.insert(log, "alt_enc " .. n .. " " .. d)
      return options.alt_enc
    end
  else
    record.alt_enc = nil
  end
  show_page("FX")
  return log, record
end

test("K1 held is ALT and its release clears it", function()
  load_strata()
  local S = local_value("S")
  key(1, 1); assert_true(S.alt_held, "K1 down is ALT")
  key(1, 0); assert_true(not S.alt_held, "K1 up clears ALT")
  S.constants.UI_PAGES.screen_dirty = false
  S.lib.ui_alt.set(true)
  assert_true(S.alt_held, "set(true) holds ALT")
  assert_true(S.constants.UI_PAGES.screen_dirty, "set requests a redraw (the hint row shows the ALT layer)")
  S.lib.ui_alt.set(false)
  assert_true(not S.alt_held, "set(false) clears it")
end)

test("ALT+K2 and ALT+K3 go to the page's alt_key through alt_action", function()
  load_strata()
  local log = logging_fx_record()
  local S = local_value("S")
  key(1, 1); tap(2); tap(3)
  assert_equal(table.concat(log, ","), "alt_key 2,alt_key_release 2,alt_key 3,alt_key_release 3",
    "ALT presses go to alt_key and their releases to alt_key_release; key and key_release never run")
  for index in pairs(log) do log[index] = nil end
  key(1, 0); tap(2)
  assert_equal(table.concat(log, ","), "key 2,key_release 2", "without ALT, K2 goes to key again")
  for index in pairs(log) do log[index] = nil end
  show_page("MAIN")
  assert_true(alt_action(S.constants.UI_PAGES.index.FX, 2), "alt_action reports that the page has alt_key")
  assert_equal(table.concat(log, ","), "alt_key 2", "alt_action runs the named page's alt_key, shown or not")
  assert_true(not alt_action(S.constants.UI_PAGES.index.SETUP, 2), "a page without alt_key: nothing runs")
  assert_true(not alt_action(0, 2) and not alt_action(S.constants.NUM_UI_PAGES + 1, 2),
    "a page index out of range does nothing")
  assert_true(not alt_action(S.constants.UI_PAGES.index.FX, 1) and not alt_action(S.constants.UI_PAGES.index.FX, 4),
    "only K2 and K3 have ALT actions")
  assert_equal(#log, 1, "nothing more ran")
end)

test("ALT+K2 on a page without alt_key never reaches its key handler", function()
  load_strata()
  local log, record = logging_fx_record()
  record.alt_key = nil; record.alt_key_release = nil
  key(1, 1); tap(2); tap(3); key(1, 0)
  assert_equal(#log, 0, "neither key nor key_release ran: " .. table.concat(log, ","))
end)

test("a key pressed with ALT releases through the ALT path", function()
  load_strata()
  local log = logging_fx_record()
  key(1, 1); key(2, 1); key(1, 0); key(2, 0)
  assert_equal(table.concat(log, ","), "alt_key 2,alt_key_release 2", "K1 let go first: still the ALT release")
  for index in pairs(log) do log[index] = nil end
  key(2, 1); key(1, 1); key(2, 0); key(1, 0)
  assert_equal(table.concat(log, ","), "key 2,key_release 2", "a plain press stays plain when K1 comes down after it")
  for index in pairs(log) do log[index] = nil end
  key(1, 1); key(2, 1); show_page("MAIN"); key(2, 0); key(1, 0)
  assert_equal(table.concat(log, ","), "alt_key 2", "an ALT press released on another page runs no release")
end)

test("a key held across a page change and back runs no release", function()
  load_strata()
  local log = logging_fx_record()
  local S = local_value("S")
  key(2, 1); show_page("MAIN")
  assert_true(S.key_press_page[2] == nil and S.key_press_alt[2] == nil, "a page change forgets the press")
  show_page("FX"); key(2, 0)
  assert_equal(table.concat(log, ","), "key 2", "a plain press released after the round trip runs no release")
  for index in pairs(log) do log[index] = nil end
  key(1, 1); key(2, 1); show_page("MAIN")
  assert_true(S.alt_held, "ALT held across E1 stays ALT")
  assert_true(S.key_press_page[2] == nil and S.key_press_alt[2] == nil, "the ALT press is forgotten too")
  assert_equal(table.concat(log, ","), "alt_key 2", "no release ran on the intermediate page")
  show_page("FX")
  assert_equal(table.concat(log, ","), "alt_key 2", "none ran on coming back")
  key(2, 0); key(1, 0)
  assert_equal(table.concat(log, ","), "alt_key 2", "an ALT press released after the round trip runs no release")
end)

test("ALT+K2 on BUFFER, K1 released first, never opens the file browser", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_source", 2)  -- voice 1 reads buffer 1, so K2's release would load
  show_page("BUFFER")
  local S = local_value("S")
  context.fileselect.last = nil
  key(1, 1); key(2, 1); key(1, 0); key(2, 0)
  assert_true(context.fileselect.last == nil, "the ALT press's release opened no file browser")
  assert_true(not S.BUFFER_PAGE.file_selector_open, "and the page still shows")
  tap(2)
  assert_true(context.fileselect.last ~= nil, "a plain K2 still opens it on release")
end)

test("the norns menu opening forgets ALT", function()
  load_strata()
  local log = logging_fx_record()
  local S = local_value("S")
  key(1, 1); key(2, 1)
  _menu.set_mode(true)
  assert_true(not S.alt_held, "ALT is forgotten as the menu opens")
  assert_true(next(S.key_press_alt) == nil, "and so is the ALT press")
  _menu.set_mode(false)
  key(2, 0)
  assert_equal(table.concat(log, ","), "alt_key 2", "the forgotten key's release does nothing")
end)

test("ALT+E2 falls through to enc when the page has no alt_enc", function()
  load_strata()
  local log = logging_fx_record()
  key(1, 1); enc(2, 1); enc(3, -2)
  assert_equal(table.concat(log, ","), "enc 2 1,enc 3 -2", "no alt_enc: enc runs")
  load_strata()
  log = logging_fx_record({ alt_enc = false })
  key(1, 1); enc(2, 1)
  assert_equal(table.concat(log, ","), "alt_enc 2 1,enc 2 1", "alt_enc returning false falls through to enc")
  load_strata()
  log = logging_fx_record({ alt_enc = true })
  enc(3, 1)
  assert_equal(table.concat(log, ","), "enc 3 1", "without ALT, alt_enc never runs")
  for index in pairs(log) do log[index] = nil end
  key(1, 1); enc(3, 1)
  assert_equal(table.concat(log, ","), "alt_enc 3 1", "alt_enc returning true handles the turn")
end)

test("E1 ignores ALT", function()
  load_strata()
  local log = logging_fx_record({ alt_enc = true })
  local S = local_value("S")
  key(1, 1); enc(1, 1)
  assert_equal(S.ui_page, S.constants.UI_PAGES.index.LFO, "E1 still steps the page with ALT held")
  assert_equal(#log, 0, "and no page handler ran: " .. table.concat(log, ","))
end)

-- K1 held as ALT is confirmed on hardware: the long-press fallback was
-- never wired, and its hook and hold time are gone (#159)
test("ALT has no long-press fallback: K1 held is the only way in", function()
  load_strata()
  local log = logging_fx_record()
  local S = local_value("S")
  assert_equal(S.lib.ui_alt.long_press, nil, "no long-press hook")
  assert_equal(S.constants.LONG_PRESS_SECONDS, nil, "no long-press hold time")
  key(2, 1); key(2, 0)
  assert_equal(table.concat(log, ","), "key 2,key_release 2", "a K2 press and release without ALT stay plain")
end)

test("an ALT release runs the hooks, from K1 up and from forget_held_keys", function()
  local context = load_strata(); finish_startup(context)
  local calls = 0
  local_value("S").register_alt_release(function() calls = calls + 1 end)
  key(1, 1); key(1, 0)
  assert_equal(calls, 1, "K1 up runs the hook")
  key(1, 1); forget_held_keys()
  assert_equal(calls, 2, "forget_held_keys runs it")
  key(1, 0)
  assert_equal(calls, 2, "a K1 release with ALT not held runs none")
  forget_held_keys()
  assert_equal(calls, 2, "forgetting with ALT not held runs none")
end)

-- #557: the shared ALT+K2 of every randomizing page (S.lib.ui_alt.k2_down,
-- k2_up, k2_hint), acting on release: a quick press randomizes or undoes,
-- one held ALT_HOLD_SECONDS runs the page's alt_hold

-- Make FX a randomizing test page: ALT+K2 through the shared handler, its
-- section one draw of the reverb mix (0.1, 0.2, ... at each draw), a hold
-- action that logs, and its hints and animates from the handler
local function randomizing_fx_record(log)
  local S = local_value("S")
  local FX = S.constants.UI_PAGES.index.FX
  local record = S.registry.pages[FX]
  local draws = 0
  record.randomize_section = function()
    return { page = FX, section = "test", draws = { { id = "reverb_mix", draw = function()
      draws = draws + 1
      return draws / 10
    end } } }
  end
  record.alt_hold = function() table.insert(log, "alt_hold") end
  record.alt_key = function(n) if n == 2 then S.lib.ui_alt.k2_down() end end
  record.alt_key_release = function(n) if n == 2 then S.lib.ui_alt.k2_up(record) end end
  record.hints = function(alt_held) return alt_held and S.lib.ui_alt.k2_hint(record) or "plain" end
  record.animates = function() return S.lib.ui_alt.k2_held() end
  show_page("FX")
  return record
end

-- MAIN's voice 1 values randomize_voice sets for a synth source
local MAIN_IDS = { "v1_freq", "v1_grain_size", "v1_grain_pitch" }
local function values_of(ids)
  local values = {}
  for _, id in ipairs(ids) do values[#values + 1] = params:get(id) end
  return table.concat(values, ",")
end

test("a quick ALT+K2 randomizes on release, not on press (#557)", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local before = values_of(MAIN_IDS)
  math.randomseed(7)
  key(1, 1); key(2, 1)
  assert_equal(values_of(MAIN_IDS), before, "the press changes nothing")
  assert_equal(local_value("undo"), nil, "and holds no undo")
  context.clock.run_for(0.49)
  key(2, 0)
  assert_true(values_of(MAIN_IDS) ~= before, "the release randomizes")
  assert_true(undo_available(1), "and holds the undo")
  key(2, 1); key(2, 0)
  assert_equal(values_of(MAIN_IDS), before, "a second quick press undoes")
  key(1, 0)
end)

test("an ALT+K2 held 0.5 s runs alt_hold and does not randomize (#557)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  assert_equal(S.constants.ALT_HOLD_SECONDS, 0.5, "ALT_HOLD_SECONDS")
  local log = {}
  randomizing_fx_record(log)
  local mix = params:get("reverb_mix")
  key(1, 1); key(2, 1)
  assert_true(S.lib.ui_alt.k2_held(), "ALT+K2 is held")
  context.clock.run_for(0.49)
  redraw(); assert_equal(hint_text(context), "K2:rand", "before the hold time: the quick press's hint")
  context.clock.run_for(0.01)
  redraw(); assert_equal(hint_text(context), "K2:reset", "from the hold time: the hold's hint")
  key(2, 0)
  assert_equal(table.concat(log, ","), "alt_hold", "the release runs alt_hold")
  assert_equal(params:get("reverb_mix"), mix, "and randomizes nothing")
  assert_equal(local_value("undo"), nil, "nor holds an undo")
  assert_true(not S.lib.ui_alt.k2_held(), "nothing is held after the release")
  redraw(); assert_equal(hint_text(context), "K2:rand", "the hint is back")
  key(1, 0)
end)

test("an ALT+K2 held 0.5 s on a page with no alt_hold shows K2:cancel and does nothing (#557)", function()
  local context = load_strata(); finish_startup(context)
  local record = randomizing_fx_record({})
  record.alt_hold = nil
  local mix = params:get("reverb_mix")
  key(1, 1); key(2, 1)
  context.clock.run_for(0.49)
  redraw(); assert_equal(hint_text(context), "K2:rand", "before the hold time: the quick press's hint")
  context.clock.run_for(0.01)
  redraw(); assert_equal(hint_text(context), "K2:cancel", "from the hold time: letting go cancels")
  key(2, 0)
  assert_equal(params:get("reverb_mix"), mix, "the release randomizes nothing")
  assert_equal(local_value("undo"), nil, "nor holds an undo")
  redraw(); assert_equal(hint_text(context), "K2:rand", "the hint is back")
  key(1, 0)
end)

test("K1 up before K2 still acts on K2's release (#557)", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local before = values_of(MAIN_IDS)
  key(1, 1); key(2, 1); key(1, 0)
  assert_equal(values_of(MAIN_IDS), before, "nothing yet")
  key(2, 0)
  assert_true(values_of(MAIN_IDS) ~= before, "the quick press randomizes at K2's release")
  local log = {}
  randomizing_fx_record(log)
  local mix = params:get("reverb_mix")
  key(1, 1); key(2, 1); key(1, 0)
  context.clock.run_for(0.6)
  key(2, 0)
  assert_equal(table.concat(log, ","), "alt_hold", "the held press runs alt_hold at K2's release")
  assert_equal(params:get("reverb_mix"), mix, "and randomizes nothing")
end)

test("a page change while ALT+K2 is held leaves no pending hold (#557)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local log = {}
  randomizing_fx_record(log)
  local mix, main_values = params:get("reverb_mix"), values_of(MAIN_IDS)
  key(1, 1); key(2, 1)
  show_page("MAIN")
  assert_true(not S.lib.ui_alt.k2_held(), "the press is forgotten with the page")
  context.clock.run_for(0.6)
  redraw(); assert_equal(hint_text(context), "K2:rand K3:lock", "MAIN offers its own randomize")
  key(2, 0)
  assert_equal(values_of(MAIN_IDS), main_values, "the release on MAIN does nothing")
  show_page("FX")
  redraw(); assert_equal(hint_text(context), "K2:rand", "back on FX: no hold is pending")
  assert_true(not S.registry.pages[S.constants.UI_PAGES.index.FX].animates(), "and the page does not animate")
  -- held across a round trip: its release on FX does nothing either
  key(2, 1); show_page("MAIN"); show_page("FX")
  context.clock.run_for(0.6)
  redraw(); assert_equal(hint_text(context), "K2:rand", "a press carried out and back holds nothing")
  key(2, 0)
  assert_equal(#log, 0, "alt_hold never ran")
  assert_equal(params:get("reverb_mix"), mix, "nothing was randomized")
  key(2, 1); key(2, 0)
  assert_true(params:get("reverb_mix") ~= mix, "a fresh quick press randomizes")
  key(1, 0)
end)

-- Review Focus 2: one undo for the whole script, offered only where it was made
test("a quick ALT+K2 on a second page within 5 s randomizes it (#557)", function()
  local context = load_strata(); finish_startup(context)
  local mutation = local_value("S").lib.mutation
  local index = local_value("S").constants.UI_PAGES.index
  show_page("MAIN")
  local original = values_of(MAIN_IDS)
  key(1, 1); tap(2)
  local randomized = values_of(MAIN_IDS)
  assert_true(randomized ~= original, "MAIN randomized voice 1")
  randomizing_fx_record({})
  local mix = params:get("reverb_mix")
  redraw(); assert_equal(hint_text(context), "K2:rand", "FX offers a randomize, not MAIN's undo")
  tap(2)
  assert_true(params:get("reverb_mix") ~= mix, "the second page randomizes")
  assert_equal(values_of(MAIN_IDS), randomized, "MAIN's randomize is not undone")
  assert_true(mutation.undo_for(index.FX, "test", nil), "the undo is the second page's")
  assert_true(not mutation.undo_for(index.MAIN, "voice", 1), "MAIN's undo is replaced")
  redraw(); assert_equal(hint_text(context), "K2:undo", "FX offers its undo")
  show_page("MAIN")
  redraw(); assert_equal(hint_text(context), "K2:rand K3:lock", "MAIN no longer offers one")
  tap(2)
  local again = values_of(MAIN_IDS)
  assert_true(again ~= randomized and again ~= original, "MAIN randomizes again, never undoes")
  key(1, 0)
end)

-- 3.4: a record's optional alt_hold_hint names its held ALT+K2 (SEQ's
-- K2:edit, MOD's K2:clear) in place of K2:reset
test("a held ALT+K2 shows the record's alt_hold_hint", function()
  local context = load_strata(); finish_startup(context)
  local record = randomizing_fx_record({})
  record.alt_hold_hint = "edit"
  key(1, 1); key(2, 1)
  context.clock.run_for(0.49)
  redraw(); assert_equal(hint_text(context), "K2:rand", "before the hold time: the quick press's hint")
  context.clock.run_for(0.01)
  redraw(); assert_equal(hint_text(context), "K2:edit", "from the hold time: the record's hint")
  record.alt_hold_hint = function() return "clear" end
  redraw(); assert_equal(hint_text(context), "K2:clear", "or what its function returns")
  record.alt_hold_hint = nil
  redraw(); assert_equal(hint_text(context), "K2:reset", "without the field: K2:reset")
  record.alt_hold, record.alt_hold_hint = nil, "edit"
  redraw(); assert_equal(hint_text(context), "K2:cancel", "a record with no alt_hold cancels, whatever its hint")
  key(2, 0); key(1, 0)
end)

end

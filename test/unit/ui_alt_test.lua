-- test/unit/ui_alt_test.lua
-- ALT (K1 held, lib/ui/alt.lua) and its dispatch in strata.lua's key and
-- enc: alt_action, the ALT press and its release, alt_enc falling through to
-- enc, and the norns menu forgetting ALT
-- Run alone: lua test/run.lua ui_alt

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, tap = h.show_page, h.tap

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
end

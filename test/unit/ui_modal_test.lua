-- test/unit/ui_modal_test.lua
-- The modal screen owner (lib/ui/modal.lua, S.lib.ui_modal): while an owner
-- is pushed it takes E2, E3, K2, K3, the screen's body and hints and the
-- arc, and E1 does nothing (strata.lua's enc, key and redraw, and
-- lib/arc/core.lua's arc_delta, arc_key and arc_redraw)
-- Run alone: lua test/run.lua ui_modal

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup, show_page = h.load_strata, h.local_value, h.finish_startup, h.show_page
local hint_text, screen_shows = h.hint_text, h.screen_shows

-- An owner that logs what reaches it and draws "probe body"
local function logging_owner(log)
  return {
    draw = function() screen.level(15); screen.move(10, 30); screen.text("probe body") end,
    hints = function(alt_held) return alt_held and "probe alt" or "probe hints" end,
    enc = function(n, d) log[#log + 1] = "enc " .. n .. " " .. d end,
    key = function(n, z) log[#log + 1] = "key " .. n .. " " .. z end,
    arc_delta = function(n, d) log[#log + 1] = "arc " .. n .. " " .. d end,
    arc_key = function(n, z) log[#log + 1] = "arc key " .. n .. " " .. z end,
    arc_redraw = function(arc_port) log[#log + 1] = "arc redraw"; arc_port:led(1, 1, 15) end,
  }
end

local function take(log)
  local text = table.concat(log, ", ")
  for index in pairs(log) do log[index] = nil end
  return text
end

test("a pushed owner takes E2, E3, K2, K3, the screen and the arc, and E1 does nothing", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  local S = local_value("S")
  local FX = S.constants.UI_PAGES.index.FX
  show_page("FX")
  local log = {}
  local owner = logging_owner(log)
  S.lib.ui_modal.push(owner)
  assert_equal(S.lib.ui_modal.top(), owner, "the owner is on top")
  local res, mix = params:get("filter_res"), params:get("master_density")

  enc(2, 1); enc(3, -2)
  assert_equal(take(log), "enc 2 1, enc 3 -2", "E2 and E3 go to the owner")
  assert_equal(params:get("master_density"), mix, "and not to FX")
  enc(1, 1)
  assert_equal(S.ui_page, FX, "E1 changes no page")
  assert_equal(take(log), "", "and never reaches the owner")

  key(3, 1); key(3, 0); key(2, 1); key(2, 0)
  assert_equal(take(log), "key 3 1, key 3 0, key 2 1, key 2 0", "K2 and K3 presses and releases go to the owner")
  key(1, 1)
  assert_equal(S.alt_held, true, "K1 still sets ALT")
  key(2, 1); key(2, 0)
  assert_equal(take(log), "key 2 1, key 2 0", "ALT+K2 goes to the owner too, never to alt_action")

  redraw()
  assert_true(screen_shows(context, "FX"), "the header still shows")
  assert_true(screen_shows(context, "probe body"), "the owner draws the body")
  assert_equal(hint_text(context), "probe alt", "and its hints, with ALT held")
  key(1, 0)
  redraw()
  assert_equal(hint_text(context), "probe hints", "and without")

  context.arc.turn(1, 2, 20)
  assert_equal(take(log), "arc 2 20", "a ring turn goes to the owner")
  assert_equal(params:get("filter_res"), res, "and not to FX's ring")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_equal(take(log), "arc key 1 1, arc key 1 0", "the arc's button goes to the owner")
  device:all(0)
  arc_redraw()
  assert_equal(take(log), "arc redraw", "the owner draws the rings")
  assert_equal(device.rings[1][1], 15, "on the followed arc")

  S.lib.ui_modal.pop(owner)
  assert_equal(S.lib.ui_modal.top(), nil, "nothing is pushed")
  enc(2, 1); key(3, 1); key(3, 0)
  assert_equal(take(log), "", "the page has the keys again")
  redraw()
  assert_true(not screen_shows(context, "probe body"), "and the screen")
  enc(1, 1)
  assert_equal(S.ui_page, FX + 1, "and E1 changes the page")
end)

test("a key that went down on the page releases into the owner and the page never sees it", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("BUFFER")  -- BUFFER's K2 release opens the file selector
  local log = {}
  key(2, 1)
  S.lib.ui_modal.push(logging_owner(log))
  key(2, 0)
  assert_equal(take(log), "key 2 0", "the release reaches the owner")
  assert_true(not S.BUFFER_PAGE.file_selector_open, "BUFFER's release never runs")
  assert_equal(S.key_press_page[2], nil, "and the press is forgotten")
  S.lib.ui_modal.pop(S.lib.ui_modal.top())
end)

test("pop of an owner that is not pushed does nothing", function()
  load_strata()
  local modal = local_value("S").lib.ui_modal
  local first, second, other = { draw = function() end }, { draw = function() end }, { draw = function() end }
  modal.push(first); modal.push(second)
  modal.pop(other)
  assert_equal(modal.top(), second, "an owner not on the stack: nothing")
  modal.pop(first)
  assert_equal(modal.top(), second, "an owner under the top leaves; the top stays")
  modal.pop(first)
  assert_equal(modal.top(), second, "a second pop of it does nothing")
  modal.pop(second)
  assert_equal(modal.top(), nil, "the stack is empty")
end)

test("push needs an owner with a draw function, once", function()
  load_strata()
  local modal = local_value("S").lib.ui_modal
  assert_true(not pcall(modal.push, {}), "an owner draws")
  assert_true(not pcall(modal.push, { draw = function() end, enc = 1 }), "enc is a function")
  assert_true(not pcall(modal.push, "owner"), "an owner is a table")
  local owner = { draw = function() end }
  modal.push(owner)
  assert_true(not pcall(modal.push, owner), "an owner on the stack is not pushed again")
  modal.pop(owner)
  assert_equal(modal.top(), nil, "one pop empties it")
end)

end

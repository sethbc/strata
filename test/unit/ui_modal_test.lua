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

-- 3.9 (#901, #899): every owner's record has a name (at most 5
-- characters, the header's title while it is on top) and a close (as its
-- own K2: here, a pop). A test owner: fields, with the name PROBE and that
-- close unless given
local function test_owner(fields)
  local owner = fields or {}
  if owner.draw == nil then owner.draw = function() end end
  if owner.name == nil then owner.name = "PROBE" end
  if owner.close == nil then owner.close = function() local_value("S").lib.ui_modal.pop(owner) end end
  return owner
end

-- An owner that logs what reaches it and draws "probe body"
local function logging_owner(log)
  return test_owner{
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
  assert_true(screen_shows(context, "PROBE"), "the header names the owner (#901)")
  assert_true(not screen_shows(context, "FX"), "in the page's title's place")
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

test("a key pressed before the owner was pushed releases into nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("BUFFER")  -- BUFFER's K2 release opens the file selector
  local log = {}
  local owner = logging_owner(log)
  key(2, 1)
  S.lib.ui_modal.push(owner)
  key(2, 0)
  assert_equal(take(log), "", "the owner never saw the press: its release does not reach it")
  assert_true(not S.BUFFER_PAGE.file_selector_open, "and BUFFER's release never runs")
  assert_equal(S.key_press_page[2], nil, "the press is forgotten")
  -- a press the owner saw releases into it, even after ALT changed
  key(3, 1); key(1, 1); key(3, 0); key(1, 0)
  assert_equal(take(log), "key 3 1, key 3 0", "the owner's own press releases into it")
  -- a press the owner saw, released after it is popped, reaches neither
  key(3, 1)
  S.lib.ui_modal.pop(owner)
  key(3, 0)
  assert_equal(take(log), "key 3 1", "the popped owner gets no release")
  -- pushed again: the old press is not its own any more
  key(2, 1)
  S.lib.ui_modal.push(owner)
  S.lib.ui_modal.pop(owner)
  S.lib.ui_modal.push(owner)
  key(2, 0)
  assert_equal(take(log), "", "a press the page took never releases into the owner")
  assert_true(not S.BUFFER_PAGE.file_selector_open, "nor into the page")
  S.lib.ui_modal.pop(owner)
end)

test("pop of an owner that is not pushed does nothing", function()
  load_strata()
  local modal = local_value("S").lib.ui_modal
  local first, second, other = test_owner(), test_owner(), test_owner()
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
  assert_true(not pcall(modal.push, test_owner{draw = false}), "an owner draws")
  assert_true(not pcall(modal.push, test_owner{enc = 1}), "enc is a function")
  assert_true(not pcall(modal.push, "owner"), "an owner is a table")
  local owner = test_owner()
  modal.push(owner)
  assert_true(not pcall(modal.push, owner), "an owner on the stack is not pushed again")
  modal.pop(owner)
  assert_equal(modal.top(), nil, "one pop empties it")
end)

-- #592: the frame clock reads a pushed owner's animates() as it reads a
-- page's, so an owner's hint or playhead moves over a page that does not
-- animate; an owner without one leaves the page's as it was
test("an owner's animates draws every frame over a page that does not; one without changes nothing (#592)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local modal = S.lib.ui_modal
  local function frames_drawn(count)
    h.next_frame(context)  -- whatever was asked for before
    local counter = h.count_screen_draws()
    for _ = 1, count do h.next_frame(context) end
    counter.restore()
    return counter.screen
  end
  show_page("MAIN")  -- its record has no animates
  assert_equal(frames_drawn(3), 0, "MAIN alone draws no frame unasked")
  local animating = true
  local owner = test_owner{animates = function() return animating end}
  modal.push(owner)
  assert_equal(frames_drawn(3), 3, "an owner that animates: every frame draws")
  animating = false
  assert_equal(frames_drawn(3), 0, "once it stops, no frame draws unasked")
  modal.pop(owner)
  local plain = test_owner()
  modal.push(plain)
  assert_equal(frames_drawn(3), 0, "an owner without animates over MAIN: no frame draws")
  modal.pop(plain)
  show_page("SEQ")
  pattern_toggle()
  modal.push(plain)
  assert_equal(frames_drawn(3), 3, "over SEQ playing, the page's animates still draws every frame")
  modal.pop(plain)
  pattern_toggle()
  local ok = pcall(modal.push, test_owner{animates = true})
  assert_true(not ok, "an owner's animates is a function")
end)


-- #866: an owner's press time, read through held_seconds(owner, n): it
-- answers only for the top owner that saw the press (inside its release
-- too), and a push forgets the covered owner's presses
test("held_seconds is nil for an owner that is not on top", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local modal = S.lib.ui_modal
  local log = {}
  local lower, upper = logging_owner(log), logging_owner({})
  local at_release
  lower.key = function(n, z)
    log[#log + 1] = "key " .. n .. " " .. z
    if z == 0 then at_release = modal.held_seconds(lower, n) end
  end
  modal.push(lower)
  context.set_time(100); key(2, 1); context.set_time(100.25)
  assert_equal(modal.held_seconds(lower, 2), 0.25, "the top owner that saw the press: how long it is held")
  assert_equal(modal.held_seconds(lower, 3), nil, "a key that is up: nil")
  assert_equal(modal.held_seconds(upper, 2), nil, "an owner that is not pushed: nil")
  context.set_time(100.5); key(2, 0)
  assert_equal(at_release, 0.5, "the owner's release reads how long the key was held")
  assert_equal(modal.held_seconds(lower, 2), nil, "after the release: nil")
  take(log)
  context.set_time(101); key(3, 1)
  modal.push(upper)
  assert_equal(modal.held_seconds(lower, 3), nil, "covered: nil")
  assert_equal(modal.held_seconds(upper, 3), nil, "the owner on top never saw the press")
  modal.pop(upper)
  assert_equal(modal.held_seconds(lower, 3), nil, "uncovered again: the press stays forgotten")
  key(3, 0)
  assert_equal(take(log), "key 3 1", "and its release reaches nothing")
  modal.pop(lower)
end)


-- 1c's review: the modal runs an owner's release before it forgets the
-- press; a release that raises still forgets it, and the error still
-- reaches the caller
test("a release handler that raises leaves no key held (a modal owner's)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local modal = S.lib.ui_modal
  local owner = logging_owner({})
  owner.key = function(_, z) if z == 0 then error("owner release failed") end end
  modal.push(owner)
  key(3, 1)
  local ok, message = pcall(key, 3, 0)
  assert_true(not ok, "the error reaches the caller")
  assert_true(tostring(message):find("owner release failed", 1, true) ~= nil, "with its message: " .. tostring(message))
  assert_true(tostring(message):find("stack traceback:", 1, true) ~= nil, "and the traceback from where it raised")
  assert_equal(modal.held_seconds(owner, 3), nil, "the key reads as up")
  modal.pop(owner)
end)


-- 3.9 (#901, #899): push checks the record's name (the header's title
-- while it is on top: a non-empty string of at most 5 characters) and its
-- close (a function)
test("push refuses an owner with no name, a longer name or no close", function()
  load_strata()
  local modal = local_value("S").lib.ui_modal
  local function refused(owner, why)
    local ok, message = pcall(modal.push, owner)
    assert_true(not ok, why)
    assert_equal(modal.top(), nil, why .. ": nothing is pushed")
    return tostring(message)
  end
  local message = refused({draw = function() end, close = function() end}, "no name")
  assert_true(message:find("name", 1, true) ~= nil, "the error names the name: " .. message)
  refused(test_owner{name = ""}, "an empty name")
  refused(test_owner{name = "SCALES"}, "a name of six characters")
  refused(test_owner{name = 5}, "a name that is no string")
  message = refused({draw = function() end, name = "PROBE"}, "no close")
  assert_true(message:find("close", 1, true) ~= nil, "the error names the close: " .. message)
  refused(test_owner{close = true}, "a close that is no function")
  local owner = test_owner{name = "SCALE"}
  modal.push(owner)
  assert_equal(modal.top(), owner, "a name of five characters and a close: pushed")
  modal.pop(owner)
end)

test("top_name names the top owner, nil with none", function()
  load_strata()
  local modal = local_value("S").lib.ui_modal
  assert_equal(modal.top_name(), nil, "no owner: nil")
  local lower, upper = test_owner{name = "LOW"}, test_owner{name = "UP"}
  modal.push(lower)
  assert_equal(modal.top_name(), "LOW", "one owner: its name")
  modal.push(upper)
  assert_equal(modal.top_name(), "UP", "the top one's")
  modal.pop(upper)
  assert_equal(modal.top_name(), "LOW", "popped: the one beneath")
  modal.pop(lower)
  assert_equal(modal.top_name(), nil, "none again: nil")
end)

-- close_all (cleanup's modal_owners step) calls each owner's close from the
-- top down; an owner its close leaves on the stack is popped with a line,
-- so the steps after it run and the stack is empty
test("close_all closes every owner from the top down", function()
  local context = load_strata()
  local modal = local_value("S").lib.ui_modal
  local closed = {}
  local function closing(name)
    local owner
    owner = test_owner{name = name, close = function() closed[#closed + 1] = name; modal.pop(owner) end}
    return owner
  end
  modal.push(closing("ONE")); modal.push(closing("TWO")); modal.push(closing("THREE"))
  modal.close_all()
  assert_equal(table.concat(closed, " "), "THREE TWO ONE", "each close, from the top down")
  assert_equal(modal.top(), nil, "the stack is empty")
  modal.close_all()
  assert_equal(#closed, 3, "with none open: nothing")
  local stuck = test_owner{name = "STUCK", close = function() end}
  modal.push(closing("BELOW")); modal.push(stuck)
  modal.close_all()
  assert_equal(modal.top(), nil, "an owner its close left on the stack is popped")
  assert_equal(closed[#closed], "BELOW", "and the one beneath it still closes")
  local said = table.concat(context.printed or {}, "\n")
  assert_true(said:find("STUCK", 1, true) ~= nil, "a line names it: " .. said)
end)

end

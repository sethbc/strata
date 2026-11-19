-- test/unit/ui_name_entry_test.lua
-- The name entry (lib/ui/name_entry.lua, S.lib.ui_name_entry, #849): the
-- one piece SCENES and the voice picker open norns' textentry through, and
-- its menu-close reconcile
-- Run alone: lua test/run.lua ui_name_entry

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function started()
  local context = load_strata(); finish_startup(context)
  return context, local_value("S")
end

test("an entry opens with its text and heading and hands back what was typed", function()
  local context, S = started()
  local closed, named = 0, {}
  local entry = S.lib.ui_name_entry.new(function() closed = closed + 1 end)
  assert_true(not entry.is_open(), "closed at first")
  key(1, 1)
  assert_true(S.alt_held, "ALT held")
  entry.open("old", "thing 1 name", function(text) named[#named + 1] = text end)
  assert_true(entry.is_open(), "open")
  assert_true(not S.alt_held, "the held keys and ALT are forgotten as it opens")
  local te = context.textentry.library
  assert_equal(te.txt, "old", "it starts from the text")
  assert_equal(te.heading, "thing 1 name", "under the heading")
  context.textentry.finish("new")
  assert_true(not entry.is_open(), "closed once it called back")
  assert_equal(closed, 1, "on_close ran once")
  assert_equal(table.concat(named, ","), "new", "done got the text")
end)

test("a canceled entry calls done with nothing, and closes", function()
  local context, S = started()
  local closed, named = 0, 0
  local entry = S.lib.ui_name_entry.new(function() closed = closed + 1 end)
  entry.open("", "heading", function() named = named + 1 end)
  key(2, 0)  -- the entry's cancel
  assert_true(not context.textentry.open, "canceled")
  assert_true(not entry.is_open(), "closed")
  assert_equal(closed, 1, "on_close ran")
  assert_equal(named, 0, "done never ran")
end)

test("an entry the norns menu took over is forgotten when the menu closes; the other entry is left alone", function()
  local context, S = started()
  local te = context.textentry.library
  local script_key, script_enc = key, enc
  local closed, named = {first = 0, second = 0}, 0
  local first = S.lib.ui_name_entry.new(function() closed.first = closed.first + 1 end)
  local second = S.lib.ui_name_entry.new(function() closed.second = closed.second + 1 end)
  first.open("", "first", function() named = named + 1 end)
  _menu.set_mode(true)
  te.enter(function() end, "pset", "PSET NAME: 1")
  context.textentry.finish("mine")
  _menu.set_mode(false)
  second.reconcile()
  assert_true(first.is_open(), "the second's reconcile leaves the first alone")
  assert_equal(closed.second, 0, "and closes nothing of its own")
  first.reconcile()
  assert_true(not first.is_open(), "the first is forgotten")
  assert_equal(closed.first, 1, "its on_close ran")
  assert_equal(named, 0, "nothing was named")
  assert_true(key == script_key and enc == script_enc, "the script's key and enc are back")
end)

test("the menu come and gone over an open entry hands it the screen back", function()
  local context, S = started()
  local te = context.textentry.library
  local entry = S.lib.ui_name_entry.new()
  entry.open("", "heading", function() end)
  _menu.set_mode(true)
  local drawn = te.redraws
  _menu.set_mode(false)  -- puts the script's redraw back and draws it
  assert_true(redraw ~= norns.none, "the script's redraw is back")
  entry.reconcile()
  assert_true(entry.is_open(), "still open")
  assert_true(redraw == norns.none, "Strata's redraw draws nothing over it")
  assert_true(te.redraws > drawn, "the entry is drawn again")
  context.textentry.finish("x")
  assert_true(not entry.is_open(), "it closes when it calls back, with no on_close")
end)

end

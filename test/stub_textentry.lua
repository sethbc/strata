-- stub_textentry.lua
-- Stand-in for norns' lua/lib/textentry.lua, returned by require("textentry")
-- in the harness. Like the library, enter(callback, default, heading, check)
-- opened from play mode keeps the globals key, enc, redraw and refresh to
-- restore, puts its own key and enc in the globals, calls norns.menu.init()
-- (whose set_mode(false) puts norns.script's redraw back, copies the globals
-- key and enc into the menu's routing and redraws the script), and only then
-- puts norns.none in the global redraw. Opened from the menu (a PARAMS text
-- param, a PSET name) it takes the menu's key instead and leaves the globals
-- alone. Either way it keeps callback in te.callback, so a second enter
-- replaces the first's (norns has one entry). Its key(2, 0) cancels, as the
-- library's does; exit() puts back what enter kept (and from play mode calls
-- norns.menu.init() again) before it calls back with te.txt, or nil on a
-- cancel. te.redraw draws nothing and counts its calls in te.redraws.
-- The test helper entry_context.finish(text) ends an open entry with text
-- (as typing it and choosing OK would), and entry_context.open says whether
-- one is open. The character wheel, DEL and the keyboard are not modeled.
-- Uses the norns, _menu, key, enc, redraw and refresh globals installed by
-- norns_stubs.

return function(entry_context)
  local te = {redraws = 0}
  entry_context.open = false

  te.enter = function(callback, default, heading, check)
    te.txt = default or ""
    te.heading = heading or ""
    te.callback = callback
    te.check = check
    entry_context.open = true
    if norns.menu.status() == false then
      te.key_restore = key
      te.enc_restore = enc
      te.redraw_restore = redraw
      te.refresh_restore = refresh
      key = te.key
      enc = te.enc
      norns.menu.init()
      redraw = norns.none
    else
      -- norns.menu.set(te.enc, te.key, te.redraw, te.refresh): the menu's
      -- own key goes to the entry until its exit
      te.key_restore = _menu.key
      _menu.key = te.key
    end
    te.redraw()
  end

  te.exit = function()
    entry_context.open = false
    if norns.menu.status() == false then
      key = te.key_restore
      enc = te.enc_restore
      redraw = te.redraw_restore
      refresh = te.refresh_restore
      norns.menu.init()
    else
      _menu.key = te.key_restore
    end
    if te.txt then te.callback(te.txt) else te.callback(nil) end
  end

  -- K2's release cancels; K3 (typing, OK) is entry_context.finish's
  te.key = function(n, z)
    if n == 2 and z == 0 then
      te.txt = nil
      te.exit()
    end
  end

  te.enc = function(n, delta) end

  te.redraw = function()
    te.redraws = te.redraws + 1
  end

  te.refresh = function() te.redraw() end

  -- Test helper: end the open entry with `text`, as typing it and OK would
  function entry_context.finish(text)
    assert(entry_context.open, "no text entry is open")
    te.txt = text
    te.exit()
  end

  return te
end

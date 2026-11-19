-- lib/ui/name_entry.lua
-- The name entry (S.lib.ui_name_entry, #849): the one piece SCENES' slot
-- names (lib/pages/scenes.lua) and the voice picker's preset names
-- (lib/ui/voice_picker.lua) open norns' textentry through. norns has one
-- textentry, which takes the global key, enc and redraw while it is open
-- and cancels on a K2 release, so each caller opens it on a key's release
-- and runs reconcile from its own menu-close hook. Fields of this module's
-- table: new. See docs/notes/lua/ui/name-entry.md.

return function(S)
  local M = {}
  local textentry = require "textentry"

  -- A caller's entry: open, is_open and reconcile. on_close (optional)
  -- runs whenever the entry closes: its callback ran (a text or a cancel)
  -- or the menu took it over
  function M.new(on_close)
    -- the callback the entry was given (nil while none is open) and
    -- Strata's key and enc as it opened
    local state = {callback = nil, script_key = nil, script_enc = nil}
    local entry = {}

    -- The entry is closed (its callback ran) or will never call back
    local function close()
      state.callback, state.script_key, state.script_enc = nil, nil, nil
      if on_close then on_close() end
      request_redraw()
    end

    function entry.is_open() return state.callback ~= nil end

    -- Open the entry from text under heading: a typed text goes to
    -- done(text), a cancel to nothing. The entry takes every key while
    -- open, K1's release with them: the held keys and ALT are forgotten
    -- first, or ALT would stay held after it
    function entry.open(text, heading, done)
      forget_held_keys()
      local function named(value)
        if state.callback ~= named then return end  -- forgotten when the menu took it over
        close()
        if value ~= nil then done(value) end
      end
      state.callback = named
      state.script_key, state.script_enc = key, enc
      textentry.enter(named, text, heading)
    end

    -- The caller's menu-close hook. Opened from the menu over Strata's (a
    -- PARAMS text param, a PSET name) the one textentry takes the callback,
    -- and Strata's never comes; its exit gives the menu its handlers back,
    -- while the globals keep Strata's entry's, which norns' set_mode(false)
    -- hands to play mode as the menu closes. So when the menu closes and
    -- the entry's callback is no longer this one's, the entry is forgotten,
    -- Strata's key and enc are put back and play mode is routed to them
    -- again (norns.menu.init: the hook runs after set_mode(false) copied the
    -- globals). When the callback is still this one's and the entry still
    -- holds the keys, the menu only came and went over it: set_mode(false)
    -- put Strata's redraw back and drew the page, so the entry takes the
    -- screen back, as its enter does. The entry's own enter (norns.menu.init
    -- from play mode) runs that second branch too, on every open: it puts
    -- its key in the global before the init, so the hook does early what
    -- enter does next (norns.none in redraw, then its own redraw). Its exit
    -- runs neither: the keys are back before its init. Acts only on its own
    -- callback, so another caller's entry is left to that caller
    function entry.reconcile()
      if state.callback == nil then return end
      if textentry.callback ~= state.callback then
        key, enc = state.script_key, state.script_enc
        close()
        norns.menu.init()
      elseif key == textentry.key then
        redraw = norns.none
        textentry.redraw()
      end
    end

    return entry
  end

  return M
end

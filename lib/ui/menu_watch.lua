-- lib/ui/menu_watch.lua
-- Forgetting held keys when the norns menu opens: the wrapper around
-- _menu.set_mode (watch_menu_opening, unwatch_menu_opening) and
-- forget_keys_held_through_menu. The functions stay global.

return function(S)
  local M = {}

  -- The norns menu (K1, or PARAMS and its file selector) takes every key
  -- while it is open, so a key released there never reaches key() and would
  -- stay "held" (on BUFFER, every later K3 would save instead of record).
  -- While the menu is open, forget every held key and the BUFFER page's K2
  -- gesture. Called as the menu opens (watch_menu_opening) and, as a fallback,
  -- on every 10 Hz drift_metro tick (end of drift_update).
  function forget_keys_held_through_menu()
    if not norns.menu.status() then return end
    forget_held_keys()
  end

  -- Every way into the norns menu (K1, a script error, a keyboard's menu key)
  -- goes through _menu.set_mode(true) (lua/core/menu.lua), looked up on _menu
  -- at each call, so a wrapper sees the menu open. cleanup puts norns' own
  -- function back; if something wrapped it after Strata, that wrapper stays
  -- and Strata's becomes a plain pass-through.
  local menu_watch = {original_set_mode = nil, wrapper = nil, active = false}

  function watch_menu_opening()
    if menu_watch.wrapper or not (_menu and _menu.set_mode) then return end
    -- both held as upvalues: the wrapper never looks up a script global, so
    -- it cannot break the system menu even if one is gone
    local original_set_mode = _menu.set_mode
    local forget_keys = forget_keys_held_through_menu
    local release_selector = release_superseded_file_selector
    menu_watch.original_set_mode = original_set_mode
    menu_watch.wrapper = function(mode)
      if mode == false and menu_watch.active then
        -- never let it stop the menu closing
        local released, release_error = pcall(release_selector)
        if not released then print("strata: file selector release failed: " .. tostring(release_error)) end
      end
      original_set_mode(mode)
      if mode == true and menu_watch.active then forget_keys() end
    end
    menu_watch.active = true
    _menu.set_mode = menu_watch.wrapper
  end

  function unwatch_menu_opening()
    menu_watch.active = false
    if menu_watch.wrapper and _menu.set_mode == menu_watch.wrapper then
      _menu.set_mode = menu_watch.original_set_mode
    end
    menu_watch.wrapper = nil
    menu_watch.original_set_mode = nil
  end

  -- Give the norns menu its own set_mode back early in cleanup(), before
  -- anything after it can fail
  S.register_cleanup(S.constants.CLEANUP_ORDER.menu_watch, function()
    unwatch_menu_opening()
  end)

  return M
end

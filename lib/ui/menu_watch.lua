-- lib/ui/menu_watch.lua
-- Forgetting held keys when the norns menu opens, and running the
-- S.registry.menu_close hooks as it closes: the wrapper around
-- _menu.set_mode (watch_menu_opening, unwatch_menu_opening) and
-- forget_keys_held_through_menu. The functions stay global.

return function(S)
  local M = {}

  -- Held from include time (lib/ui/keys.lua, which defines forget_held_keys,
  -- is included before this module), so neither the wrapper nor the 10 Hz
  -- fallback looks up a script global: a cleanup that stopped before its
  -- menu watch step leaves the wrapper in place after norns swaps the
  -- globals away (#425)
  local forget_held = forget_held_keys
  local menu_status = norns.menu.status

  -- The norns menu (K1, or PARAMS and its file selector) takes every key
  -- while it is open, so a key released there never reaches key() and would
  -- stay "held" (on BUFFER, every later K3 would save instead of record).
  -- While the menu is open, forget every held key and the BUFFER page's K2
  -- gesture. Called as the menu opens (watch_menu_opening) and, as a fallback,
  -- on every 10 Hz drift_metro tick (end of drift_update).
  function forget_keys_held_through_menu()
    if not menu_status() then return end
    forget_held()
  end

  -- Every way into the norns menu (K1, a script error, a keyboard's menu key)
  -- goes through _menu.set_mode(true) (lua/core/menu.lua), looked up on _menu
  -- at each call, so a wrapper sees the menu open. cleanup puts norns' own
  -- function back; if something wrapped it after Strata, that wrapper stays
  -- and Strata's becomes a plain pass-through.
  local menu_watch = {original_set_mode = nil, wrapper = nil, active = false}

  function watch_menu_opening()
    if menu_watch.wrapper or not (_menu and _menu.set_mode) then return end
    -- all held as upvalues: the wrapper never looks up a script global, so
    -- it cannot break the system menu even if one is gone. The menu-close
    -- hooks are read now (hooks register at include time)
    local original_set_mode = _menu.set_mode
    local forget_keys = forget_keys_held_through_menu
    local release_selector = release_superseded_file_selector
    local menu_close_hooks = S.registry.menu_close
    menu_watch.original_set_mode = original_set_mode
    menu_watch.wrapper = function(mode)
      if not menu_watch.active then return original_set_mode(mode) end
      if mode == false then
        -- never let it stop the menu closing
        local released, release_error = pcall(release_selector)
        if not released then print("strata: file selector release failed: " .. tostring(release_error)) end
      end
      -- norns' own set_mode(false) ends with the script's redraw(): an error
      -- there must not skip the close hooks, so it is raised again only once
      -- they have run (#425)
      local switched, switch_error = pcall(original_set_mode, mode)
      if mode == true then
        -- a failing ALT-release hook must not stop the menu opening
        local forgot, forget_error = pcall(forget_keys)
        if not forgot then print("strata: forgetting held keys failed: " .. tostring(forget_error)) end
      elseif mode == false then
        -- each hook on its own: one that fails prints a line, and the others
        -- still run
        for _, hook in ipairs(menu_close_hooks) do
          local ran, hook_error = pcall(hook)
          if not ran then print("strata: menu close hook failed: " .. tostring(hook_error)) end
        end
      end
      if not switched then error(switch_error, 0) end
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

  -- Forget held keys the moment the norns menu opens, from init on
  S.register_start(S.constants.START_ORDER.menu_watch, function()
    watch_menu_opening()
  end)

  -- Give the norns menu its own set_mode back early in cleanup(), before
  -- anything after it can fail
  S.register_cleanup(S.constants.CLEANUP_ORDER.menu_watch, function()
    unwatch_menu_opening()
  end)

  return M
end

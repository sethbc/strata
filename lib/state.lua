-- lib/state.lua
-- The table S that strata.lua and its modules share: the registries now,
-- and the script-level state that more than one module uses as it moves out
-- of strata.lua. The one module constructor that takes no argument:
-- strata.lua runs `local S = include("lib/state")()`. Every call builds a
-- fresh table, so a script reload (which runs strata.lua again) never keeps
-- state from the previous run

return function()
  local M = {}

  -- Registries modules add to as they load (the Wave 0 moves fill them)
  M.registry = {
    pages = {},         -- one record per screen page
    params = {},        -- param-adding functions, run by init in order
    cleanup = {},       -- cleanup functions, run by cleanup()
    grid_layouts = {},  -- per grid layout, its page records
  }

  return M
end

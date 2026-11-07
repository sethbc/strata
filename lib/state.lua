-- lib/state.lua
-- The table S that strata.lua and its modules share: the registries now,
-- and the script-level state that more than one module uses as it moves out
-- of strata.lua. The one module constructor that takes no argument:
-- strata.lua runs `local S = include("lib/state")()`. Every call builds a
-- fresh table, so a script reload (which runs strata.lua again) never keeps
-- state from the previous run

return function()
  local M = {}

  -- Every key ever assigned into S, even to nil (a clock that is not
  -- running): M.__declared[name] = true. The test harness finds such a
  -- name in S while its value is nil. Assigning to a key that holds a value
  -- skips __newindex, but that key was recorded when it was first set
  rawset(M, "__declared", {})
  setmetatable(M, {
    __newindex = function(table, key, value)
      rawget(table, "__declared")[key] = true
      rawset(table, key, value)
    end,
  })

  -- Registries modules add to as they load (the Wave 0 moves fill them)
  M.registry = {
    pages = {},         -- one record per screen page
    params = {},        -- param-adding functions, run by init in order
    cleanup = {},       -- cleanup functions, run by cleanup()
    grid_layouts = {},  -- per grid layout ("256", "128h", ...), its {key, redraw}
  }

  return M
end

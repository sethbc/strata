-- lib/state.lua
-- The table S that strata.lua and its modules share: the registries, the
-- module tables (S.lib) and the script-level state that more than one
-- module uses. The one module constructor that takes no argument:
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

  -- Registries modules add to as they load
  M.registry = {
    pages = {},         -- one record per screen page
    params = {},        -- param-adding functions, run by init in order
    start = {},         -- {order, fn} records, run by init() by order
    cleanup = {},       -- {order, fn} records, run by cleanup() by order
    grid_layouts = {},  -- per grid layout ("256", "128h", ...), its {key, redraw}
  }

  -- Add an {order, fn} record to one of the ordered registries (start or
  -- cleanup). Two steps never share an order (table.sort is not stable, so a
  -- tie would run in no fixed order)
  local function register_step(steps, kind, order, fn)
    assert(type(order) == "number", "a " .. kind .. " step needs a number order")
    assert(type(fn) == "function", "a " .. kind .. " step needs a function")
    for _, record in ipairs(steps) do
      assert(record.order ~= order, "two " .. kind .. " steps at order " .. order)
    end
    steps[#steps + 1] = {order = order, fn = fn}
  end

  -- Each module adds one start step per thing it must start: init() in
  -- strata.lua runs fn of every record in ascending order, after the params
  -- are added and their actions wrapped. The orders are
  -- S.constants.START_ORDER, so the whole sequence reads in one place
  function M.register_start(order, fn)
    register_step(M.registry.start, "start", order, fn)
  end

  -- Each module adds one cleanup step per thing it must stop or save on
  -- exit: cleanup() in strata.lua runs fn of every record in ascending
  -- order. The orders are S.constants.CLEANUP_ORDER
  function M.register_cleanup(order, fn)
    register_step(M.registry.cleanup, "cleanup", order, fn)
  end

  -- The module tables, S.lib.<name> (strata.lua stores each constructor's
  -- table here)
  M.lib = {}

  return M
end

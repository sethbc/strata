-- lib/playheads.lua
-- Where each voice's grains read, for the playhead marks on the screen,
-- the grid and the arc. Neutral until its Wave 1 package (3.3's
-- playheads): the functions answer as pinned below and send nothing.

return function(S)
  local M = {}

  -- A voice's read position (0-1), or nil
  function M.position(v) return nil end
  -- A voice's position spread, or nil
  function M.spread(v) return nil end
  -- A slot's record head (0-1), or nil
  function M.record_head(slot) return nil end
  -- A voice's column among `columns`, or nil
  function M.column(v, columns) return nil end
  -- Forget a voice's playhead
  function M.reset(v) end

  return M
end

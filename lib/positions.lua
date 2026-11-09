-- lib/positions.lua
-- Moving a voice's read position: jumps, loops, bookmarks, scan hold and
-- scrub, from the screen, the grid and the arc. Neutral until its Wave 1
-- package (3.3's positions): the functions answer as pinned below and
-- send nothing.

return function(S)
  local M = {}

  function M.jump(v, p) end
  function M.set_loop(v, a, b) end
  function M.recall_bookmark(v, n) end
  function M.store_bookmark(v, n) end
  function M.hold_scan(v, on) end
  function M.scrub_turned(v) end
  function M.grid_key(port, v, cell, cells, z) end
  function M.strip_key(port, v, key, z) end
  -- A voice's bookmark n (0-1), or nil
  function M.bookmark(v, n) return nil end
  -- The bookmark a voice last recalled, or nil
  function M.last_recalled(v) return nil end
  -- LED levels for the grid's position row and the 128 grid's strip
  function M.grid_level(v, cell, cells) return 0 end
  function M.strip_level(v, key) return 0 end

  return M
end

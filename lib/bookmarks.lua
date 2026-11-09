-- lib/bookmarks.lua
-- A voice's bookmarks (NUM_BOOKMARKS read positions). Neutral until its
-- Wave 1 package (3.3's positions): the functions answer as pinned below
-- and send nothing.

return function(S)
  local M = {}

  -- Recall a voice's bookmark n
  function M.recall(v, n) end
  -- Whether a voice's bookmark n holds a position
  function M.is_set(v, n) return false end

  return M
end

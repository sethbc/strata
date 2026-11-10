-- lib/bookmarks.lua
-- A voice's bookmarks (NUM_BOOKMARKS read positions): the two functions
-- 3.4's step locks call, built on lib/positions.lua. Neither ever creates a
-- node: recall sends params:set calls and one setGrainParam (never voiceOn
-- or setGrainSource). See docs/notes/lua/bookmarks.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BOOKMARKS = S.constants.NUM_BOOKMARKS

  -- Whether a voice's bookmark n holds a position: a whole voice in
  -- 1..NUM_VOICES, a whole n in 1..NUM_BOOKMARKS, and a voice that reads a
  -- slot whose reported seconds are above 0
  function M.is_set(v, n)
    if type(v) ~= "number" or v < 1 or v > NUM_VOICES or v % 1 ~= 0 then return false end
    if type(n) ~= "number" or n < 1 or n > NUM_BOOKMARKS or n % 1 ~= 0 then return false end
    local slot = voice_buffer_slot(v)
    return slot ~= nil and S.buffers[slot] ~= nil and (S.buffers[slot].seconds or 0) > 0
  end

  -- Recall a voice's bookmark n (a no-op unless it is set)
  function M.recall(v, n)
    if M.is_set(v, n) then S.lib.positions.recall_bookmark(v, n) end
  end

  return M
end

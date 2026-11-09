-- lib/files.lua
-- The audio folder and the sample files BUFFER fills slots from.
-- Neutral until its Wave 1 package (3.3's files): the functions answer as
-- pinned below and send nothing.

return function(S)
  local M = {}

  -- The folder a slot's file chooser opens in
  function M.folder_for(slot) return _path.audio end
  -- Fill a slot with a random file from the folder; whether it did
  function M.random_into(slot) return false end
  -- Fill every empty slot; how many it filled
  function M.fill_empty() return 0 end
  -- Note the file the user chose (its folder becomes the next default)
  function M.note_chosen(path) end
  M.last_folder = nil

  return M
end

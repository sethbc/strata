-- lib/files.lua
-- The audio folder and the sample files BUFFER fills slots from: the folder a
-- slot's files come from, a random file into a slot and the empty slots
-- filled from one folder. Every load goes through load_buffer (at start 0).
-- Not recursive: util.scandir lists one folder.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS

  -- the folder BUFFER's file selector last chose a file from (this session)
  M.last_folder = nil

  -- the file types a slot loads (lower case; names are compared lower-cased)
  local SOUND_EXTENSIONS = { wav = true, aif = true, aiff = true, flac = true, ogg = true }

  -- The folder of a path, with its trailing "/", or nil for a bare name
  local function folder_of(path)
    if type(path) ~= "string" then return nil end
    return path:match("^(.*/)")
  end

  -- The folder a slot's files come from: the folder of the slot's file (a
  -- recorded take's scratch folder is nobody's library, so a take has none),
  -- else the folder of the last file chosen in BUFFER's selector, else
  -- _path.audio
  function M.folder_for(slot)
    local buffer = S.buffers[slot]
    if buffer and buffer.path and buffer.path ~= scratch_take_path(slot) then
      local folder = folder_of(buffer.path)
      if folder then return folder end
    end
    return M.last_folder or _path.audio
  end

  -- BUFFER's file selector chose path: its folder is the next default
  function M.note_chosen(path)
    local folder = folder_of(path)
    if folder then M.last_folder = folder end
  end

  -- The sound files in folder, by name: not folders (ls -p marks them with
  -- "/"), not dot files
  local function sound_files(folder)
    local found = {}
    for _, name in ipairs(util.scandir(folder)) do
      local extension = name:match("%.([^./]+)$")
      if name:sub(1, 1) ~= "." and name:sub(-1) ~= "/" and extension and SOUND_EXTENSIONS[extension:lower()] then
        found[#found + 1] = name
      end
    end
    return found
  end

  -- Fill slot with a random sound file from its folder, other than the file
  -- it holds when the folder has another; whether it loaded
  function M.random_into(slot)
    if type(slot) ~= "number" or slot < 1 or slot > NUM_BUFFERS or slot % 1 ~= 0 then return false end
    local folder = M.folder_for(slot)
    local names = sound_files(folder)
    if #names == 0 then
      buffer_page_flash("no files in " .. folder)
      return false
    end
    local candidates = names
    if #names >= 2 then
      candidates = {}
      for _, name in ipairs(names) do
        if folder .. name ~= S.buffers[slot].path then candidates[#candidates + 1] = name end
      end
    end
    local name = candidates[math.random(1, #candidates)]
    load_buffer(slot, folder .. name, 0)
    buffer_page_flash("buf " .. slot .. ": " .. name)
    return true
  end

  -- A slot with nothing loaded, recording or armed
  local function slot_is_empty(slot)
    local buffer = S.buffers[slot]
    return not buffer.loaded and not buffer.recording and not buffer.finishing
      and S.lib.record.state(slot) == nil
  end

  -- Give every empty slot a distinct random sound file from the folder of the
  -- BUFFER page's cursor slot, until the files run out; how many slots filled
  function M.fill_empty()
    local folder = M.folder_for(S.buffer_page.slot)
    local names = sound_files(folder)
    if #names == 0 then
      buffer_page_flash("no files in " .. folder)
      return 0
    end
    -- a file another slot holds is not given again
    local in_use = {}
    for slot = 1, NUM_BUFFERS do
      if S.buffers[slot].path then in_use[S.buffers[slot].path] = true end
    end
    for index = #names, 1, -1 do
      if in_use[folder .. names[index]] then table.remove(names, index) end
    end
    local filled = 0
    for slot = 1, NUM_BUFFERS do
      if #names == 0 then break end
      if slot_is_empty(slot) then
        load_buffer(slot, folder .. table.remove(names, math.random(1, #names)), 0)
        filled = filled + 1
      end
    end
    buffer_page_flash("filled " .. filled .. " slots")
    return filled
  end

  return M
end

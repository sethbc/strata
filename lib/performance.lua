-- lib/performance.lua
-- The performance setting (S.lib.performance). The engine decides the tier
-- at alloc, from the setting Lua saved (performance.data), the board model
-- and the free memory, and writes what it runs to performance_active.data
-- before the script starts. read_active (the first params record, so it
-- runs before any param is added) reads that file into S.performance; a
-- missing or invalid file gives the standard tier. setting/set_setting read
-- and write performance.data, which only the SETUP page edits: no param,
-- PSET or scene holds it. See docs/notes/lua/performance.md.

return function(S)
  local M = {}
  local STANDARD_PERFORMANCE = S.constants.STANDARD_PERFORMANCE

  -- The files (in _path.data .. "strata/", the folder the engine's
  -- settingsDir defaults to), the setting's choices and defaults, and what
  -- each tier may hold. Each must equal the engine's (StrataPerformance.sc:
  -- highBufferChoices, highHistorySeconds, the area's maxGrains)
  local PERFORMANCE = {
    setting_file = "performance.data",
    active_file = "performance_active.data",
    choices = {"auto", "standard", "high"},
    buffer_choices = {16, 60, 120, 300},  -- ascending, SETUP's order
    default_setting = {performance = "auto", buffer_seconds = 60},
    tiers = {
      standard = {buffer_seconds = {STANDARD_PERFORMANCE.buffer_seconds},
        max_grains = STANDARD_PERFORMANCE.max_grains, history_seconds = STANDARD_PERFORMANCE.history_seconds},
      high = {buffer_seconds = {16, 60, 120, 300}, max_grains = 128, history_seconds = 60},
    },
    unreadable_line = "strata: performance_active.data unreadable, using standard",
  }
  M.PERFORMANCE = PERFORMANCE

  -- The setting as SETUP shows it (nil until first read), and the setting
  -- this start used: the file as init found it, which the engine read at
  -- alloc just before. SETUP marks a setting that differs from it "(next start)"
  S.performance_setting = nil
  S.performance_start_setting = nil

  local function data_dir() return _path.data .. "strata/" end

  local function includes(list, value)
    for _, item in ipairs(list) do
      if item == value then return true end
    end
    return false
  end

  -- A file's text, or nil when it cannot be read
  local function read_text(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return type(text) == "string" and text or nil
  end

  -- "key value" lines into a table (value: the rest of the line, trimmed).
  -- Blank lines are skipped; a line with no value gives that key an empty
  -- string. accept(key, value), when given, drops the lines it refuses, so
  -- a repeated key keeps its last accepted value (as the engine reads
  -- performance.data); otherwise the last line of a key wins
  local function key_values(text, accept)
    local fields = {}
    for line in text:gmatch("[^\n]+") do
      local key, value = line:match("^%s*([%w_]+)%s*(.-)%s*$")
      if key and (not accept or accept(key, value)) then fields[key] = value end
    end
    return fields
  end

  local function whole_number(text)
    if type(text) ~= "string" or not text:match("^%d+$") then return nil end
    return tonumber(text)
  end

  -- The active file's values from its text, or nil when any is missing or
  -- not one the tier allows (a garbled, truncated or foreign file). The
  -- engine stub validates the test's active file with this too
  -- (stubs.active_buffer_seconds), so the stub and Lua never disagree
  function M.parse_active_text(text)
    if type(text) ~= "string" then return nil end
    local fields = key_values(text)
    local allowed = PERFORMANCE.tiers[fields.tier]
    if not allowed then return nil end
    local buffer_seconds = whole_number(fields.buffer_seconds)
    local max_grains = whole_number(fields.max_grains)
    local history_seconds = whole_number(fields.history_seconds)
    if not includes(allowed.buffer_seconds, buffer_seconds) or max_grains ~= allowed.max_grains
      or history_seconds ~= allowed.history_seconds then
      return nil
    end
    return {tier = fields.tier, buffer_seconds = buffer_seconds, max_grains = max_grains,
      history_seconds = history_seconds, reason = fields.reason or ""}
  end

  -- Fill S.performance from performance_active.data (the "performance"
  -- params record: before any param is added, so every tier-dependent spec
  -- reads it). Anything missing or invalid gives the standard tier and one
  -- console line. Also reads the setting this start used
  function M.read_active()
    local active = M.parse_active_text(read_text(data_dir() .. PERFORMANCE.active_file))
    if not active then
      print(PERFORMANCE.unreadable_line)
      active = {reason = ""}
      for key, value in pairs(STANDARD_PERFORMANCE) do active[key] = value end
    end
    S.performance = active
    S.performance_setting = nil
    S.performance_start_setting = M.setting()
  end

  -- A valid performance.data line
  local function valid_setting_line(key, value)
    if key == "performance" then return includes(PERFORMANCE.choices, value) end
    if key == "buffer_seconds" then return includes(PERFORMANCE.buffer_choices, whole_number(value)) end
    return false
  end

  -- The setting in performance.data: {performance, buffer_seconds}. Each
  -- key is read on its own, as the engine reads it: invalid lines are
  -- skipped, so a key keeps its last valid value, and a missing file or a
  -- key with no valid line gives that key's default (auto, 60 s); other
  -- keys are ignored
  local function read_setting()
    local fields = key_values(read_text(data_dir() .. PERFORMANCE.setting_file) or "", valid_setting_line)
    return {performance = fields.performance or PERFORMANCE.default_setting.performance,
      buffer_seconds = whole_number(fields.buffer_seconds) or PERFORMANCE.default_setting.buffer_seconds}
  end

  -- A copy of the setting (read from the file the first time)
  function M.setting()
    if not S.performance_setting then S.performance_setting = read_setting() end
    return {performance = S.performance_setting.performance, buffer_seconds = S.performance_setting.buffer_seconds}
  end

  -- Change one key ("performance" or "buffer_seconds") and save the
  -- setting: written to a temporary file in the folder, then renamed over
  -- performance.data, so a crash never leaves half a file. Returns false
  -- (changing nothing) for an unknown key or a value outside its choices
  function M.set_setting(key, value)
    local choices = key == "performance" and PERFORMANCE.choices
      or key == "buffer_seconds" and PERFORMANCE.buffer_choices
    if not choices or not includes(choices, value) then return false end
    local setting = M.setting()
    setting[key] = value
    S.performance_setting = setting
    local path = data_dir() .. PERFORMANCE.setting_file
    local part_path = path .. ".part"
    util.make_dir(data_dir())
    local file = io.open(part_path, "w")
    local written = false
    if file then
      written = file:write("performance " .. setting.performance .. "\n"
        .. "buffer_seconds " .. setting.buffer_seconds .. "\n") ~= nil
      written = file:close() and written
    end
    if not (written and os.rename(part_path, path)) then
      os.remove(part_path)
      print("strata: cannot write " .. path)
    end
    request_redraw()
    return true
  end

  return M
end

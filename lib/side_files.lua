-- lib/side_files.lua
-- A module's two kinds of data file (S.lib.side_files, #648): its live file
-- in data/strata/ and its file beside each PSET (<path_base><side_suffix>),
-- both {version = <version>, [<key>] = <data>}, through S.lib.data_files.
-- The macros, the gestures and the matrix each make one with new(spec);
-- what their data is, how it validates, what an unknown id in it means and
-- the redraws stay theirs. new(spec) returns:
--   read(path, silent)   load the file (nothing when missing; an unusable
--                        one set aside with one console line, nothing
--                        loaded); whether path may be written over
--   write(path)          write the data; whether it was written
--   load_live()          the start step: read the live file; one that could
--                        be neither used nor set aside is never written over
--   save_live()          the live file's timed write, one per burst
--   save_now()           the cleanup step: the timed write canceled, the
--                        live file written at once
--   pset_hook(before, after)  the record S.register_pset_hook takes
-- See docs/notes/lua/data-files.md (Side files).

return function(S)
  local M = {}

  -- The live files' folder
  local LIVE_DIR = _path.data .. "strata/"

  local REQUIRED = {
    {field = "name", kind = "string"}, {field = "contents", kind = "string"}, {field = "version", kind = "number"},
    {field = "key", kind = "string"}, {field = "live_file", kind = "string"}, {field = "side_suffix", kind = "string"},
    {field = "backup_suffix", kind = "string"}, {field = "capture", kind = "function"},
    {field = "validate", kind = "function"}, {field = "load", kind = "function"},
  }

  local function check(spec)
    if type(spec) ~= "table" then error("side_files.new: a spec is a table", 3) end
    for _, required in ipairs(REQUIRED) do
      if type(spec[required.field]) ~= required.kind then
        error("side_files.new: the spec's " .. required.field .. " is a " .. required.kind, 3)
      end
    end
    if spec.save_delay and (type(spec.save_delay) ~= "number" or type(spec.clock_field) ~= "string") then
      error("side_files.new: a save_delay is a number of seconds with a clock_field naming its clock in S", 3)
    end
  end

  -- A module's files, from its spec (lib/side_files.lua's header; the
  -- fields are named in docs/notes/lua/data-files.md)
  function M.new(spec)
    check(spec)
    local files = {}
    -- loaded: the start step read the live file, found it missing or set it
    -- aside, so it may be written over
    local live = {path = LIVE_DIR .. spec.live_file, loaded = false}
    if spec.save_delay then S[spec.clock_field] = nil end  -- the timed write's clock, while it waits

    -- Write the data to path (none too, so a PSET saved over never keeps
    -- an older side file). Returns whether it was written
    function files.write(path)
      local written, detail = S.lib.data_files.write(path, {version = spec.version, [spec.key] = spec.capture()})
      if not written then print("error: " .. spec.name .. " not saved to " .. path .. " (" .. tostring(detail) .. ")") end
      return written
    end

    -- Load the data from path: a missing file loads nothing; one that
    -- cannot be used (unreadable, another version, refused by validate) is
    -- set aside (path .. backup_suffix, ...) with a console line, and
    -- nothing loads. Returns whether path may be written over: false only
    -- for a file that could not be used and could not be set aside
    function files.read(path, silent)
      local loaded, problem, detail = S.lib.data_files.read(path)
      local why
      if loaded == nil and problem ~= "missing" then
        why = tostring(detail)
      elseif loaded ~= nil then
        if type(loaded) ~= "table" or loaded.version ~= spec.version then
          why = "not a version " .. spec.version .. " " .. spec.name .. " file"
        else
          why = spec.validate(loaded[spec.key])
        end
      end
      local writable = true
      if why then
        local backup, failure = S.lib.data_files.set_aside(path, spec.backup_suffix)
        print("error loading " .. spec.name .. " file " .. path .. ": " .. why .. "; "
          .. (backup and ("kept as " .. backup) or ("not moved: " .. tostring(failure))))
        loaded = nil
        writable = backup ~= nil
      end
      spec.load(loaded and loaded[spec.key] or nil, path, silent)
      return writable
    end

    -- The start step's read. One that could be neither read nor set aside
    -- is never written over (scenes.data's rule, #590): nothing is saved in
    -- this session, which one line says
    function files.load_live()
      live.loaded = files.read(live.path)
      if not live.loaded then
        print(spec.name .. ": " .. live.path .. " could not be read or moved aside; the " .. spec.contents
          .. " will not be saved this session")
      end
      return live.loaded
    end

    local function write_live()
      if not live.loaded then return end
      if util.file_exists(LIVE_DIR) == false then util.make_dir(LIVE_DIR) end
      files.write(live.path)
    end

    -- The live file follows the data once the start step loaded it: one
    -- write save_delay s after the first change of a burst, carrying the
    -- newest data, from S[clock_field]
    function files.save_live()
      if not spec.save_delay then error("side_files: " .. spec.name .. " has no timed write", 2) end
      if not live.loaded or S[spec.clock_field] then return end
      S[spec.clock_field] = clock.run(function()
        clock.sleep(spec.save_delay)
        S[spec.clock_field] = nil
        write_live()
      end)
    end

    -- The cleanup step: the timed write is canceled and the live file is
    -- written at once
    function files.save_now()
      if spec.save_delay and S[spec.clock_field] then
        clock.cancel(S[spec.clock_field])
        S[spec.clock_field] = nil
      end
      write_live()
    end

    -- The PSET's side file: written with every PSET save (empty too),
    -- read after every PSET load (before_read and after_read around the
    -- read, each with the read's silent flag), deleted with the PSET
    function files.pset_hook(before_read, after_read)
      return {
        name = spec.name,
        write = function(path_base) files.write(path_base .. spec.side_suffix) end,
        read = function(path_base, _, _, silent)
          if before_read then before_read(silent) end
          files.read(path_base .. spec.side_suffix, silent)
          if after_read then after_read(silent) end
        end,
        delete = function(path_base) os.remove(path_base .. spec.side_suffix) end,
      }
    end

    return files
  end

  return M
end

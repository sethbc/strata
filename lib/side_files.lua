-- lib/side_files.lua
-- A module's two kinds of data file (S.lib.side_files, #648): its live file
-- in data/strata/ and its file beside each PSET (<path_base><side_suffix>),
-- both {version = <version>, [<key>] = <data>}, through S.lib.data_files;
-- a spec's optional floor lets a file from floor to version load.
-- The macros, the gestures, the matrix, the sequences and the scenes each
-- make one with new(spec) (the scenes for their PSET file only: their live
-- file keeps its own writer, lib/scenes.lua);
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
--   pset_hook(before_read, after_read, after_write, after_delete)  the
--                        record S.register_pset_hook takes
-- and the module's read_only(fn) and reading_only() (3.8): while fn runs,
-- no read sets a file aside (a factory set's, in the script's folder), and
-- writer(spec) (3.9, #906): the one debounced writer of a live file, which
-- save_live and save_now run on, and buffers.data's and samples.data's.
-- See docs/notes/lua/data-files.md (Side files).

return function(S)
  local M = {}

  -- The live files' folder
  local LIVE_DIR = _path.data .. "strata/"
  -- skipped: how an unusable file's line ends while reading only (3.8)
  local SIDE_FILES = {skipped = "a factory file, never moved: skipped"}
  M.SIDE_FILES = SIDE_FILES

  -- Set while read_only(fn) runs fn (3.8, 4d): every read then leaves an
  -- unusable file where it is
  local reading_only = false

  -- xpcall's handler: the traceback of where fn raised, unless an inner
  -- handler added one already, so the error raised again still says where
  local function with_traceback(message)
    if tostring(message):find("stack traceback:", 1, true) then return message end
    return debug.traceback(tostring(message), 2)
  end

  -- Run fn with every side file read only: an unusable file is never set
  -- aside, one line says it was skipped, and its module loads it as a
  -- missing file (load(nil)). After fn, an error included (raised again
  -- with its traceback), the flag is what it was before: a nested call
  -- leaves the outer one's set (#847). A factory set's files are read so
  -- (S.lib.factory), in the script's own folder
  function M.read_only(fn)
    if type(fn) ~= "function" then error("side_files.read_only: fn is a function", 2) end
    local outer = reading_only
    reading_only = true
    local ok, problem = xpcall(fn, with_traceback)
    reading_only = outer
    if not ok then error(problem, 0) end
  end

  function M.reading_only()
    return reading_only
  end

  local WRITER_REQUIRED = {
    {field = "name", kind = "string"}, {field = "value", kind = "function"}, {field = "holder", kind = "table"},
    {field = "clock_field", kind = "string"}, {field = "may_write", kind = "function"},
  }

  -- One live file's debounced writer (3.9, #906): the one rule every file
  -- Strata writes after a change follows (the side files' live files,
  -- buffers.data and samples.data; scenes.data keeps its own). spec:
  --   name         the console word, in a raised error
  --   path         the file's path, or a function giving it at each write
  --   value()      the table written, read at each write
  --   holder, clock_field   the timed write's clock waits in
  --                holder[clock_field] (nil when none waits)
  --   may_write()  whether the file may be written now (its start step
  --                read it, and it is not one that could not be set aside)
  --   text_field   optional: holder[text_field] keeps the text last
  --                written (or found by the start step); no timed write
  --                starts or runs while value() would write that text
  --   save_delay   optional: s from a burst's first change to its write
  --   report(written, detail, path)   optional: after each write
  -- It returns:
  --   write()      write the file now, whatever may_write says (its folder
  --                made first): written and detail, as data_files.write
  --   save()       one write save_delay s after the first change of a
  --                burst, carrying the newest data; none after save_now
  --   save_now()   the cleanup step: the timed write canceled (the one
  --                place it is) and the file written at once if it may be
  function M.writer(spec)
    if type(spec) ~= "table" then error("side_files.writer: a spec is a table", 2) end
    for _, required in ipairs(WRITER_REQUIRED) do
      if type(spec[required.field]) ~= required.kind then
        error("side_files.writer: the spec's " .. required.field .. " is a " .. required.kind, 2)
      end
    end
    if type(spec.path) ~= "string" and type(spec.path) ~= "function" then
      error("side_files.writer: the spec's path is a string or a function", 2)
    end
    local writer = {}
    local holder, clock_field, text_field = spec.holder, spec.clock_field, spec.text_field or nil
    -- the cleanup step's write ran: no timed write starts after it (a later
    -- cleanup step may change the data, #651)
    local closed = false

    local function unchanged()
      return text_field ~= nil and S.lib.data_files.encode(spec.value()) == holder[text_field]
    end

    function writer.write()
      local path = type(spec.path) == "function" and spec.path() or spec.path
      local folder = path:match("^(.*/)")
      if folder and util.file_exists(folder) == false then util.make_dir(folder) end
      local value = spec.value()
      local written, detail = S.lib.data_files.write(path, value)
      if written and text_field then holder[text_field] = S.lib.data_files.encode(value) end
      if spec.report then spec.report(written, detail, path) end
      return written, detail
    end

    function writer.save()
      if not spec.save_delay then error("side_files: " .. spec.name .. " has no timed write", 2) end
      if closed or holder[clock_field] or not spec.may_write() or unchanged() then return end
      holder[clock_field] = clock.run(function()
        clock.sleep(spec.save_delay)
        holder[clock_field] = nil
        if spec.may_write() and not unchanged() then writer.write() end
      end)
    end

    function writer.save_now()
      if holder[clock_field] then
        clock.cancel(holder[clock_field])
        holder[clock_field] = nil
      end
      closed = true
      if not spec.may_write() then return false, "may not be written" end
      return writer.write()
    end

    return writer
  end

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
    local floor_version = spec.floor
    if floor_version ~= nil and (type(floor_version) ~= "number" or floor_version > spec.version) then
      error("side_files.new: a floor is a number no higher than the version", 3)
    end
  end

  -- A module's files, from its spec (lib/side_files.lua's header; the
  -- fields are named in docs/notes/lua/data-files.md)
  function M.new(spec)
    check(spec)
    local files = {}
    local needs_backup = {}  -- paths whose last ordinary read could neither use nor set aside the file
    -- loaded: the start step read the live file, found it missing or set it
    -- aside, so it may be written over (the writer's closed says the cleanup
    -- step wrote it)
    local live = {path = LIVE_DIR .. spec.live_file, loaded = false}
    if spec.save_delay then S[spec.clock_field] = nil end  -- the timed write's clock, while it waits
    -- the versions a read takes: floor (the version without one) to
    -- version, and how a refused file's line names them
    local floor_version = spec.floor or spec.version
    local versions = floor_version == spec.version and tostring(spec.version)
      or (floor_version .. "-" .. spec.version)

    -- Write the data to path (none too, so a PSET saved over never keeps
    -- an older side file). Returns whether it was written
    local function value() return {version = spec.version, [spec.key] = spec.capture()} end
    local function report(written, detail, path)
      if not written then print("error: " .. spec.name .. " not saved to " .. path .. " (" .. tostring(detail) .. ")") end
    end
    function files.write(path)
      if needs_backup[path] then
        local backup, why = S.lib.data_files.set_aside(path, spec.backup_suffix)
        if not backup then
          report(false, why, path)
          return false
        end
        needs_backup[path] = nil
      end
      local written, detail = S.lib.data_files.write(path, value())
      report(written, detail, path)
      return written
    end

    -- Load the data from path: a missing file loads nothing; one that
    -- cannot be used (unreadable, a version outside floor..version, refused
    -- by validate) is
    -- set aside (path .. backup_suffix, ...) with a console line, and
    -- nothing loads. Returns whether path may be written over: false only
    -- for a file that could not be used and could not be set aside
    function files.read(path, silent)
      local loaded, problem, detail = S.lib.data_files.read(path)
      local why
      if loaded == nil and problem ~= "missing" then
        why = tostring(detail)
      elseif loaded ~= nil then
        local version = type(loaded) == "table" and loaded.version
        -- a whole number from the floor to the version (NaN, 2.5 and a
        -- string are none)
        if type(version) ~= "number" or version ~= math.floor(version) or not (version >= floor_version)
          or not (version <= spec.version) then
          why = "not a version " .. versions .. " " .. spec.name .. " file"
        else
          why = spec.validate(loaded[spec.key])
        end
      end
      local writable = true
      if why and reading_only then
        -- a factory set's file (read_only): never moved, loaded as missing
        print("error loading " .. spec.name .. " file " .. path .. ": " .. why .. "; " .. SIDE_FILES.skipped)
        loaded = nil
      elseif why then
        local backup, failure = S.lib.data_files.set_aside(path, spec.backup_suffix)
        print("error loading " .. spec.name .. " file " .. path .. ": " .. why .. "; "
          .. (backup and ("kept as " .. backup) or ("not moved: " .. tostring(failure))))
        loaded = nil
        writable = backup ~= nil
      end
      if not reading_only then needs_backup[path] = not writable or nil end
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

    -- The live file's timed write and the cleanup step's, through the one
    -- writer (M.writer): once the start step loaded it, one write
    -- save_delay s after the first change of a burst, carrying the newest
    -- data, from S[clock_field]; never after the cleanup step's write (a
    -- later cleanup step may change the data: the gestures' stop of every
    -- recorder ends a recording, which that write already held)
    local live_writer = M.writer({name = spec.name, path = live.path, value = value, report = report,
      holder = spec.save_delay and S or live, clock_field = spec.clock_field or "save_clock",
      save_delay = spec.save_delay, may_write = function() return live.loaded end})

    function files.save_live()
      if not spec.save_delay then error("side_files: " .. spec.name .. " has no timed write", 2) end
      live_writer.save()
    end

    -- The cleanup step: the timed write is canceled and the live file is
    -- written at once, its last write of the session
    function files.save_now()
      live_writer.save_now()
    end

    -- The PSET's side file: written with every PSET save (empty too; then
    -- after_write(written, path_base)), read after every PSET load
    -- (before_read and after_read around the read, each with the read's
    -- silent flag), deleted with the PSET (then after_delete(path_base))
    function files.pset_hook(before_read, after_read, after_write, after_delete)
      return {
        name = spec.name,
        write = function(path_base)
          local written = files.write(path_base .. spec.side_suffix)
          if after_write then after_write(written, path_base) end
        end,
        read = function(path_base, _, _, silent)
          if before_read then before_read(silent) end
          files.read(path_base .. spec.side_suffix, silent)
          if after_read then after_read(silent) end
        end,
        delete = function(path_base)
          local path = path_base .. spec.side_suffix
          if os.remove(path) then needs_backup[path] = nil end
          if after_delete then after_delete(path_base) end
        end,
      }
    end

    return files
  end

  return M
end

-- lib/factory.lua
-- The factory sets (3.8, design §9), S.lib.factory: a set is a folder of
-- the script, factory/<key>/ (set.params, the five side files, set.samples.data
-- and audio/), listed by factory/index.data. A load runs in one clock,
-- S.factory_clock: the audio is copied to audio/strata/factory/<key>-<version>/
-- (each file to a .part renamed into place, a file there left alone), each
-- file's settings stored (S.lib.samples.store_file), the live scenes kept
-- (S.lib.scenes.back_up_live), the sound params set from set.params in menu
-- order (a rig param's line, FACTORY.rig, and norns' own refused; a sound
-- param without a line to its load default), the side files read through
-- their PSET hooks inside S.lib.side_files.read_only, the set's name flashed
-- and factory.data (the marker: the sets loaded, by version, and a first
-- run's pending set) written. The start step runs a first run's load; the
-- cleanup step cancels the clock and closes the list; SETUP's factory sets row opens the list
-- (a modal owner). Fields of this module's table: FACTORY, sets, load,
-- loading, parse_params, is_rig, open_list, close_list, is_open. See
-- docs/notes/lua/factory.md.

return function(S)
  local M = {}

  -- The files' versions: factory.data (the marker, from its floor),
  -- index.data and set.samples.data
  local FACTORY_DATA_VERSION = 1
  local FACTORY_FORMAT_FLOOR = 1
  local FACTORY_INDEX_DATA_VERSION = 1
  local FACTORY_SET_DATA_VERSION = 1

  -- The names: the folders and files (folder and index under the script's
  -- folder, norns.state.path; marker under data/strata/; install_folder
  -- under _path.audio), a key's pattern (util.make_dir runs mkdir -p
  -- unquoted, so a key holds nothing a shell splits), the copy's chunk, the
  -- PSET hooks a set's side files are read through (by name, in registry
  -- order; voice_presets reads no file: it clears the voices' preset names,
  -- as at a PSET read, #861), the marker's backup suffix; the rig (the params a set never
  -- moves: every param of these menu groups and every id these patterns
  -- match, ruling 52); the list's layout and texts
  local FACTORY = {
    folder = "factory/", index = "index.data", marker = "factory.data", data_folder = "strata/",
    params_file = "set.params", samples_file = "set.samples.data", side_base = "set", audio_folder = "audio/",
    install_folder = "strata/factory/", key_pattern = "^[%w_%-]+$", copy_chunk_bytes = 1048576,
    backup_suffix = ".bak", pset_hooks = {"scenes", "macros", "morph", "gestures", "sequences", "matrix",
      "voice_presets"},
    rig = {
      groups = {"strata_midi", "strata_zones", "strata_out_midi", "strata_crow", "strata_out_ii", "strata_out_nb",
        "strata_tape", "strata_record", "strata_input"},
      patterns = {"^midi_", "^mpe_", "^v%d+_out_", "^v%d+_zone", "^cc_out%d+_", "^crow_", "^jf_", "^wsyn_", "^txo_",
        "^tapeloop", "^record_source$", "^record_feedback$", "^record_loop$", "^record_threshold$", "^record_sync$",
        "^record_beats$", "^input_follow_gain$", "^tempo$", "^seq_follow_transport$"},
    },
    list = {visible = 6, first_y = 18, spacing = 7, value_right = 124, version_gap = 4, levels = {selected = 15, other = 4}},
    texts = {none = "none", loading = "loading", refused = "set not loaded"},
    -- the versions an index and a set's samples file are written at (a
    -- test's or a layout state's, #847)
    index_version = FACTORY_INDEX_DATA_VERSION, set_version = FACTORY_SET_DATA_VERSION,
  }
  M.FACTORY = FACTORY

  S.factory_clock = nil  -- the load's clock while it runs

  local function index_path() return norns.state.path .. FACTORY.folder .. FACTORY.index end
  local function set_folder(key) return norns.state.path .. FACTORY.folder .. key .. "/" end
  local function marker_path() return _path.data .. FACTORY.data_folder .. FACTORY.marker end
  local function install_folder(set) return _path.audio .. FACTORY.install_folder .. set.key .. "-" .. set.version .. "/" end

  local function whole(value, low)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value < math.huge
  end
  local function is_key(value) return type(value) == "string" and value:match(FACTORY.key_pattern) ~= nil end
  -- a file of the set's audio folder: a bare name, no folder and no ..
  local function is_file_name(value)
    return type(value) == "string" and value ~= "" and not value:find("/", 1, true) and value ~= "." and value ~= ".."
  end

  ---------------------------------------------------------------------------
  -- The rig and the parser
  ---------------------------------------------------------------------------

  -- Whether a param id is rig: a param of a FACTORY.rig group, or an id one
  -- of its patterns matches (the groups' params all match one, a test
  -- walks them)
  function M.is_rig(param_id)
    if type(param_id) ~= "string" then return false end
    for _, pattern in ipairs(FACTORY.rig.patterns) do
      if param_id:match(pattern) then return true end
    end
    return false
  end

  -- A PSET's text as norns' params:read reads it: {[id] = the line's raw
  -- value}, the first line of an id winning, "--" lines no lines
  -- (S.lib.params_setup.pset_line, the one reader of a line)
  function M.parse_params(text)
    local lines = {}
    if type(text) ~= "string" then return lines end
    local pset_line = S.lib.params_setup.pset_line
    for line in text:gmatch("[^\n]+") do
      local id, value = pset_line(line)
      if id and lines[id] == nil then lines[id] = value end
    end
    return lines
  end

  ---------------------------------------------------------------------------
  -- The index and the marker
  ---------------------------------------------------------------------------

  -- Why an index's value cannot be used, or nil
  local function index_problem(index)
    if type(index) ~= "table" or index.version ~= FACTORY_INDEX_DATA_VERSION then
      return "not a version " .. FACTORY_INDEX_DATA_VERSION .. " index"
    end
    if type(index.sets) ~= "table" then return "no list of sets" end
    local keys = {}
    for position, set in ipairs(index.sets) do
      if type(set) ~= "table" or not is_key(set.key) or type(set.name) ~= "string" or not whole(set.version, 1) then
        return "set " .. position .. " is no {key, name, version}"
      end
      if keys[set.key] then return "set " .. set.key .. " is listed twice" end
      keys[set.key] = true
    end
    if index.first_run ~= nil and not keys[index.first_run] then return "the first run names no set" end
    return nil
  end

  -- The index, or nil: none (3.8 ships none) or one that cannot be used
  -- (one line; it is the script's, never moved)
  local function read_index()
    local index, problem, detail = S.lib.data_files.read(index_path())
    if index == nil and problem == "missing" then return nil end
    local why = index == nil and tostring(detail) or index_problem(index)
    if why then
      print("factory: " .. index_path() .. " not read: " .. why)
      return nil
    end
    return index
  end

  local function find_set(index, key)
    if not index then return nil end
    for _, set in ipairs(index.sets) do
      if set.key == key then return set end
    end
    return nil
  end

  -- The sets the index lists ({key, name, version} each, copies), in order;
  -- empty with no index
  function M.sets()
    local list = {}
    local index = read_index()
    for _, set in ipairs(index and index.sets or {}) do
      list[#list + 1] = {key = set.key, name = set.name, version = set.version}
    end
    return list
  end

  local function marker_problem(marker)
    if type(marker) ~= "table" or not whole(marker.version, FACTORY_FORMAT_FLOOR)
      or marker.version > FACTORY_DATA_VERSION then
      return "not a version " .. FACTORY_DATA_VERSION .. " factory file"
    end
    if marker.pending ~= nil and not is_key(marker.pending) then return "its pending set is no key" end
    if type(marker.loaded) ~= "table" then return "no table of loaded sets" end
    for key, version in pairs(marker.loaded) do
      if not is_key(key) or not whole(version, 1) then return "a loaded set is no key and version" end
    end
    return nil
  end

  -- The marker: {pending, loaded}, and whether a file was found (an
  -- unusable one is set aside, one line, and counts as found, with nothing
  -- loaded and nothing pending: a damaged marker never loads a set over a
  -- player). If the backup fails, nil means the original must stay in place.
  local function read_marker()
    local marker, problem, detail = S.lib.data_files.read(marker_path())
    if marker == nil and problem == "missing" then return {loaded = {}}, false end
    local why = marker == nil and tostring(detail) or marker_problem(marker)
    if why then
      local backup, failure = S.lib.data_files.set_aside(marker_path(), FACTORY.backup_suffix)
      print("error loading factory file " .. marker_path() .. ": " .. why .. "; "
        .. (backup and ("kept as " .. backup) or ("not moved: " .. tostring(failure))))
      if not backup then return nil, true end
      return {loaded = {}, backed_up = true}, true
    end
    return {pending = marker.pending, loaded = marker.loaded}, true
  end

  local function write_marker(marker)
    local folder = _path.data .. FACTORY.data_folder
    if util.file_exists(folder) == false then util.make_dir(folder) end
    local written, detail = S.lib.data_files.write(marker_path(),
      {version = FACTORY_DATA_VERSION, pending = marker.pending, loaded = marker.loaded})
    if not written then print("error: factory file not saved to " .. marker_path() .. " (" .. tostring(detail) .. ")") end
    return written
  end

  ---------------------------------------------------------------------------
  -- The load
  ---------------------------------------------------------------------------

  -- set.samples.data's files ({[name] = record}), or nil and why
  local function read_samples(key)
    local path = set_folder(key) .. FACTORY.samples_file
    local value, problem, detail = S.lib.data_files.read(path)
    if value == nil and problem == "missing" then return {} end
    if value == nil then return nil, tostring(detail) end
    if type(value) ~= "table" or value.version ~= FACTORY_SET_DATA_VERSION or type(value.files) ~= "table" then
      return nil, "not a version " .. FACTORY_SET_DATA_VERSION .. " samples file"
    end
    for name, record in pairs(value.files) do
      if not is_file_name(name) or type(record) ~= "table" then return nil, "a file entry is no name and record" end
    end
    return value.files
  end

  -- Copy source to destination in copy_chunk_bytes chunks (a clock.sleep(0)
  -- between chunks), through destination .. ".part" renamed into place; the
  -- open (io.open looked up at each call), each read and write, the flush and the
  -- close are checked. true, or false and why (the .part removed)
  local function copy_file(source, destination)
    local input, open_problem = io.open(source, "rb")
    if not input then return false, "cannot be read (" .. tostring(open_problem) .. ")" end
    local part = destination .. ".part"
    local output, problem = io.open(part, "wb")
    if not output then
      input:close()
      return false, tostring(problem)
    end
    local failure
    while true do
      local chunk, read_problem = input:read(FACTORY.copy_chunk_bytes)
      if read_problem then
        failure = read_problem
        break
      end
      if not chunk or chunk == "" then break end
      local written, write_problem = output:write(chunk)
      if not written then
        failure = write_problem or "the write failed"
        break
      end
      if #chunk == FACTORY.copy_chunk_bytes then clock.sleep(0) end
    end
    input:close()
    if not failure then
      local flushed, flush_problem = output:flush()
      if not flushed then failure = flush_problem or "the flush failed" end
    end
    local closed, close_problem = output:close()
    if not failure and not closed then failure = close_problem or "the close failed" end
    if failure then
      os.remove(part)
      return false, tostring(failure)
    end
    local renamed, rename_problem = os.rename(part, destination)
    if not renamed then
      os.remove(part)
      return false, tostring(rename_problem)
    end
    return true
  end

  -- A file's size in bytes, or nil when it cannot be opened
  local function file_size(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
  end

  -- Step 1: every file set.samples.data names copied to the install folder,
  -- in name order, a clock.sleep(0) after each; a file there of the set's
  -- file's size left alone (one of another size, cut short by a power cut
  -- the copy's lack of fsync allows, is copied again through its .part).
  -- Returns the installed names ({[name] = true}) and the missing ones (one
  -- line each), or nil when a copy failed (one line: the load stops)
  local function install(set, files)
    local folder = install_folder(set)
    util.make_dir(folder)
    local names = {}
    for name in pairs(files) do names[#names + 1] = name end
    table.sort(names)
    local installed, missing = {}, {}
    for _, name in ipairs(names) do
      local destination = folder .. name
      local source = set_folder(set.key) .. FACTORY.audio_folder .. name
      local source_size = file_size(source)
      if util.file_exists(destination) and (source_size == nil or file_size(destination) == source_size) then
        installed[name] = true
      elseif source_size == nil then
        print("factory: " .. set.key .. ": " .. name .. " is missing from the set; its slot line is skipped")
        missing[name] = true
      else
        local copied, why = copy_file(source, destination)
        if not copied then
          print("factory: " .. set.key .. " not loaded: " .. name .. " could not be installed (" .. why .. ")")
          return nil
        end
        installed[name] = true
      end
      clock.sleep(0)
    end
    return installed, missing
  end

  -- Whether a param may take a set's line or its load default: a Strata
  -- record param that is not rig, is saved and is no trigger, separator or
  -- group
  local function sound_param(param)
    if param == nil or M.is_rig(param.id) or param.save == false then return false end
    if param.t == params.tSEPARATOR or param.t == params.tGROUP or param.t == params.tTRIGGER then return false end
    if param.t == params.tBINARY and param.behavior == "trigger" then return false end
    return true
  end

  -- A line's value for param, as norns' read takes it, or nil and why: a
  -- text param the text; a file param its file in the install folder
  -- (installed); a number param the number rounded; the others the number
  -- (inf and -inf as norns reads them)
  local function line_value(param, raw, set, installed, missing)
    if param.t == params.tTEXT then return raw end
    if param.t == params.tFILE then
      if not is_file_name(raw) then return nil, "names no file of the set's audio" end
      if missing[raw] then return nil end  -- install's line named it
      if not installed[raw] then return nil, "names " .. raw .. ", which is not installed" end
      return install_folder(set) .. raw
    end
    local value = tonumber(raw)
    if value == nil and raw == "inf" then value = math.huge end
    if value == nil and raw == "-inf" then value = -math.huge end
    if value == nil then return nil, "holds no number" end
    if param.t == params.tNUMBER then value = util.round(value) end
    return value
  end

  -- Step 4: the set's lines. A line naming a rig param, a param that is no
  -- Strata record param (norns' own) or no param is refused, one line each;
  -- then every sound param, in menu order (the scale, the tuning and a
  -- voice's quantize come before its freq), through its own set: its line,
  -- or its load default when the set has none (a file param has none: the
  -- slot keeps its audio)
  local function apply_params(set, lines, installed, missing)
    local setup = S.lib.params_setup
    local ids = setup.record_param_ids()
    local strata = {}
    for _, id in ipairs(ids) do strata[id] = true end
    local named = {}
    for id in pairs(lines) do named[#named + 1] = id end
    table.sort(named)
    for _, id in ipairs(named) do
      local why
      if M.is_rig(id) then why = "a rig param"
      elseif not params.lookup[id] then why = "no param"
      elseif not strata[id] then why = "norns' own param"
      elseif not sound_param(params:lookup_param(id)) then why = "never saved"
      end
      if why then print("factory: " .. set.key .. ": the line for " .. id .. " is refused (" .. why .. ")") end
    end
    for voice_idx = 1, S.constants.NUM_VOICES do S.lib.types.cancel(voice_idx) end
    for _, id in ipairs(ids) do
      local param = params:lookup_param(id)
      if sound_param(param) then
        local raw = lines[id]
        if raw ~= nil then
          local value, why = line_value(param, raw, set, installed, missing)
          if value == nil and why then
            print("factory: " .. set.key .. ": the line for " .. id .. " is skipped (" .. why .. ")")
          elseif value ~= nil then
            param:set(value)
          end
        else
          local default = setup.load_default(param)
          if default ~= nil then param:set(default) end
        end
      end
    end
  end

  -- Step 5: the five side files, through their modules' PSET hooks (each
  -- one's own before and after hooks run), read only
  local function read_side_files(set)
    local path_base = set_folder(set.key) .. FACTORY.side_base
    local wanted = {}
    for _, name in ipairs(FACTORY.pset_hooks) do wanted[name] = true end
    S.lib.side_files.read_only(function()
      for _, hook in ipairs(S.registry.pset_hooks) do
        if wanted[hook.name] and hook.read then
          local ran, failure = pcall(hook.read, path_base, nil, path_base .. ".params", false)
          if not ran then print("factory: " .. set.key .. ": pset hook " .. hook.name .. ": " .. tostring(failure)) end
        end
      end
    end)
  end

  -- Step 6: a whole load is marked (loaded[key] = its version, pending
  -- cleared), the name flashed
  local function finish(set)
    local marker = read_marker()
    if marker then
      marker.loaded[set.key] = set.version
      marker.pending = nil
      write_marker(marker)
    end
    header_flash(set.name)
    request_redraw()
    grid_redraw()
  end

  local function run_load(set, files, lines)
    clock.sleep(0)  -- the start goes on first; a first run's marker is written before any file
    local installed, missing = install(set, files)
    if not installed then return end
    local names = {}
    for name in pairs(installed) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      if not S.lib.samples.store_file(install_folder(set) .. name, files[name]) then
        print("factory: " .. set.key .. ": " .. name .. "'s settings are refused; it keeps none")
      end
    end
    local kept, why = S.lib.scenes.back_up_live()
    if not kept then
      print("factory: " .. set.key .. " not loaded: the scenes in no PSET could not be kept (" .. tostring(why) .. ")")
      S.lib.ui_flash.start("hints", FACTORY.texts.refused)
      return
    end
    -- from here the live file is set aside: whatever the rest does (the
    -- set's scenes taken or not, a step that raises), the scenes in memory
    -- are written back before the step ends
    local ran, failure = pcall(function()
      -- step 4 begins: a running scene fade ends where it is, so none of
      -- its later steps or its landing sets params over the set's (#859)
      cancel_scene_transition()
      apply_params(set, lines, installed, missing)
      read_side_files(set)
    end)
    S.lib.scenes.autosave()
    if not ran then error(failure, 0) end
    finish(set)
  end

  function M.loading() return S.factory_clock ~= nil end

  -- Load the set key: true, or false and why ("loading": one runs; "no
  -- set": the index lists none of that key; "unreadable": its files)
  function M.load(key)
    if S.factory_clock then return false, "loading" end
    if not is_key(key) then return false, "no set" end
    local set = find_set(read_index(), key)
    if not set then return false, "no set" end
    local files, why = read_samples(key)
    if not files then
      print("factory: " .. key .. " not loaded: " .. set_folder(key) .. FACTORY.samples_file .. ": " .. why)
      return false, "unreadable"
    end
    local text = S.lib.data_files.read_text(set_folder(key) .. FACTORY.params_file)
    if not text then
      print("factory: " .. key .. " not loaded: " .. set_folder(key) .. FACTORY.params_file .. " cannot be read")
      return false, "unreadable"
    end
    local lines = M.parse_params(text)
    S.factory_clock = clock.run(function()
      local ran, failure = pcall(run_load, set, files, lines)
      S.factory_clock = nil
      if not ran then error(failure, 0) end
    end)
    return true
  end

  -- cleanup()'s step: the load's clock canceled where it is (a copy cut
  -- short leaves its .part, which the next load writes over, and marks
  -- nothing), and SETUP's list closed, its owner popped (#847)
  S.register_cleanup(S.constants.CLEANUP_ORDER.factory, function()
    if S.factory_clock then
      clock.cancel(S.factory_clock)
      S.factory_clock = nil
    end
    M.close_list()
  end)

  ---------------------------------------------------------------------------
  -- The first run and the cleanup
  ---------------------------------------------------------------------------

  -- The start step (ruling 51), after the live files are read and before
  -- any voice starts: with no index, nothing (and nothing is written). A
  -- marker holding pending (a set the index lists) runs that load again,
  -- whatever this start found; no marker, no scenes file found at this
  -- start and a first-run set write {pending = <key>, loaded = {}} and
  -- start its load (not awaited); no marker otherwise writes {loaded = {}}.
  -- A pending load refused (its files unreadable: load's one line) clears
  -- pending, so it is not tried, and its line not printed, at every start (#847)
  S.register_start(S.constants.START_ORDER.factory_first_run, function()
    local index = read_index()
    if not index then return end
    local marker, found = read_marker()
    if not marker then return end
    if marker.pending and find_set(index, marker.pending) then
      if not M.load(marker.pending) then write_marker({loaded = marker.loaded}) end
      return
    end
    if found then
      if marker.backed_up then write_marker(marker) end
      return
    end
    if S.scene_file.start_outcome == "missing" and index.first_run then
      if write_marker({pending = index.first_run, loaded = {}}) and not M.load(index.first_run) then
        write_marker({loaded = {}})
      end
      return
    end
    write_marker({loaded = {}})
  end)

  ---------------------------------------------------------------------------
  -- SETUP's list (a modal owner)
  ---------------------------------------------------------------------------

  -- open; the cursor (an index into sets); the sets listed at open; the
  -- armed prompt's end (util.time(); 0: not armed). While armed the
  -- prompt is the list's own hint row, whatever flashes (#897, as SCENES'
  -- overwrite prompt since #255): the next K3 loads, so it always says so
  local list = {open = false, cursor = 1, sets = {}, armed_until = 0}
  local owner

  local function list_flash(text, seconds)
    S.lib.ui_flash.start("hints", text, seconds, S.constants.UI_PAGES.index.SETUP)
  end

  local function draw_row(row, y, selected, value_right)
    local layout = FACTORY.list
    screen.level(selected and layout.levels.selected or layout.levels.other)
    screen.move(0, y)
    local version = "v" .. row.set.version
    local room = value_right - screen.text_extents(version) - layout.version_gap
    screen.text(S.lib.ui_text.fit_text(S.lib.ui_text.printable(row.set.name), room))
    screen.move(value_right, y)
    screen.text_right(version)
  end

  local function draw()
    if not list.open then return end
    local layout = FACTORY.list
    if #list.sets == 0 then
      screen.level(layout.levels.other)
      screen.move(0, layout.first_y)
      screen.text(FACTORY.texts.none)
      return
    end
    local rows = {}
    for index, set in ipairs(list.sets) do rows[index] = {label = set.name, set = set} end
    S.lib.ui_field_list.draw(rows, list.cursor, {visible = layout.visible, first_y = layout.first_y,
      spacing = layout.spacing, value_right = layout.value_right}, draw_row)
  end

  -- Armed: the first K3's prompt has not lapsed
  local function armed()
    return util.time() < list.armed_until
  end

  -- Under ALT K3 does nothing (key), so the armed prompt, which names K3,
  -- shows with ALT up only (#897 review)
  local function hints(alt_held)
    if armed() and not alt_held then return S.lib.pages_setup.SETUP_PAGE.load_texts.confirm end  -- load scenes' prompt
    local flash = S.lib.ui_flash.text("hints")
    if flash then return flash end
    if #list.sets == 0 then return alt_held and "" or "K2:back" end
    if alt_held then return "E2:set" end
    return "K2:back E2:set K3:load"
  end

  local function enc(n, d)
    if not list.open or n ~= 2 or #list.sets == 0 then return end
    list.cursor = util.clamp(list.cursor + d, 1, #list.sets)
    request_redraw()
  end

  -- K3: the set under the cursor loads; while a scene of this session is
  -- not on disk the first press arms for SCENE_LOAD.confirm_seconds and a
  -- second inside it loads, as load scenes asks
  local function press_load()
    local set = list.sets[list.cursor]
    if not set then return end
    if M.loading() then
      list_flash(FACTORY.texts.loading)
      return
    end
    local confirm_seconds = S.lib.scenes.SCENE_LOAD.confirm_seconds
    if S.scene_file.unsaved and not armed() then
      list.armed_until = util.time() + confirm_seconds
      request_redraw()
      return
    end
    list.armed_until = 0
    local loaded = M.load(set.key)
    list_flash(loaded and FACTORY.texts.loading or FACTORY.texts.refused)
  end

  local function key(n, z)
    if not list.open or z ~= 1 or S.alt_held then return end
    if n == 2 then
      M.close_list()
    elseif n == 3 then
      press_load()
    end
  end

  -- The frame clock draws the list every frame while armed: the prompt
  -- lapses with no clock of its own. Once lapsed it disarms and returns
  -- true once more, for the frame that takes the prompt off the hint row
  local function animates()
    if list.armed_until == 0 then return false end
    if not armed() then list.armed_until = 0 end
    return true
  end

  -- SETS in the header while it is on top (#901); close as K2 (#899)
  owner = {name = "SETS", close = function() M.close_list() end,
    draw = draw, hints = hints, enc = enc, key = key, animates = animates}

  -- Open the list over SETUP (its factory sets row): the index's sets, read
  -- now; already open, nothing
  function M.open_list()
    if list.open then return end
    list.open, list.cursor, list.armed_until = true, 1, 0
    list.sets = M.sets()
    S.lib.ui_modal.push(owner)
  end

  function M.close_list()
    if not list.open then return end
    list.open = false
    S.lib.ui_modal.pop(owner)
  end

  function M.is_open() return list.open end

  -- The load's clock runs exactly while a load runs (its coroutine alive);
  -- the open list's owner is the modal one (or beneath SEQ's step editor),
  -- the closed list's never; the cursor is on a set
  S.register_invariant("factory", function()
    local thread = S.factory_clock and clock.threads and clock.threads[S.factory_clock]
    if S.factory_clock and (thread == nil or coroutine.status(thread) == "dead") then
      return "S.factory_clock " .. tostring(S.factory_clock) .. " is no live clock"
    end
    local top = S.lib.ui_modal.top()
    if not list.open and top == owner then return "the list is closed but its owner is the modal one" end
    if list.open and top ~= owner and not (top == S.lib.pages_seq.step_editor_owner and S.lib.pages_seq.step_editor()) then
      return "the list is open but the modal owner is " .. tostring(top)
    end
    if list.open and #list.sets > 0 and (list.cursor < 1 or list.cursor > #list.sets) then
      return "the cursor is on " .. tostring(list.cursor) .. " of " .. #list.sets
    end
  end)

  return M
end

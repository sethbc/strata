-- lib/pages/setup.lua
-- The SETUP page: a field list (MIDI port, channel mode, 3.5's note off,
-- mpe & zones (K3 opens S.lib.ui_zones' editor) and note pool, mutations
-- on/off, rate, probability, amount, save scenes, load scenes, each grid
-- port's rotation, the performance setting and its buffer length; 3.8's
-- scale & tuning (K3 opens S.lib.ui_scale_editor's editor) and factory sets
-- (K3 opens S.lib.factory's list)) with the status
-- lines (the running tier,
-- grids, arc, buffers) below it; E2 moves the cursor, E3 edits the field's
-- value, K3 runs an action field (save, load, mpe & zones). It scrolls like FX
-- (S.lib.ui_field_list). The performance fields edit the setting
-- (S.lib.performance), the rotation fields S.lib.grid_core's, the note pool
-- S.lib.notes', not params.
-- Registers its S.registry.pages record.
-- The functions that were global stay global.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local UI_PAGES = S.constants.UI_PAGES
  local NOTE_POOL = S.constants.NOTE_POOL
  local field_list = S.lib.ui_field_list

  local SETUP_PAGE = {
    visible = 6,          -- rows at y 18-53, 7 px apart (a descender clears the next row, #422), clear of the hint row
    first_y = 18,
    spacing = 7,
    value_right = 124,    -- the scroll marker owns x 127
    note_indent = 8,      -- a field's dim note row ("(next start)", ...) starts here
    xrun_platforms = {[2] = true, [3] = true},  -- norns.platform: CM3, Pi 3 (matron's platform.h)
    xrun_note = "may xrun",  -- the performance fields' and the note pool's warning
    -- the hint row's flash for each answer of S.lib.scenes.request_load
    load_texts = {loaded = "scenes loaded", missing = "no scenes file", unreadable = "scenes unreadable",
      older = "scenes older", confirm = "K3 again: drop unsaved"},
    -- the status rows for a data file with a problem (S.scene_file,
    -- S.buffer_file), after its label ("scenes", "buffers"): kept, a file
    -- that could not be read and was moved to the backup the note row names;
    -- unreadable, one still in place, which is not saved over; older_kept
    -- and older, the same for a scenes file of an older Strata (a format
    -- below the floor); not saved, a write that failed
    file_texts = {kept = " unreadable, kept", unreadable = " file unreadable", ["not saved"] = " file not saved",
      older_kept = " older, kept", older = " file older", kept_note = "as ", in_place_note = "not saved over",
      -- 3.9 (#895): any other data file's note while it is still in place
      -- (whether a later change writes over it is the file's own rule,
      -- docs/notes/lua/data-files.md)
      left_note = "left in place",
      -- a file that parsed and was set aside by its reader, which names no
      -- cause (another version, a refused shape, or voices.data's damaged
      -- presets kept while its good ones loaded): moved, or not moved
      set_aside = " set aside", not_moved = " file not moved"},
    data_suffix = "%.data$",  -- left off a file's name in its row's label
    -- 3.9 (#931): after a connected grid's size with no layout
    -- (S.lib.grid_core.layout_of)
    no_layout = " no layout",
    -- a grid port's rotation field (kind "rotation", #323): its setting
    -- (S.lib.grid_core.rotation, 0-3) shown in degrees; the fields, one per
    -- port, are made at the first look (grid core sets S.MAX_GRID_PORTS)
    rotation_degrees = 90,
    rotation_fields = {},
  }
  M.SETUP_PAGE = SETUP_PAGE

  -- The fields, in cursor order. Each row starts with its label. kind
  -- "param": E3 edits param_id, shown with format (a string.format pattern,
  -- or the param's own string); the MIDI port's row reads "<label> <port>:
  -- <device>". kind "action": K3 calls run and hint names the K3 hint (run
  -- looks the scenes function up as it runs, so a test can stand in for it)
  -- and flashes what it did (#463): the load asks for a second K3 while a
  -- scene of this session is not on disk (#328). 3.5's three rows follow
  -- channels whatever its mode (no field moves when it changes, ruling 10):
  -- the note off param; mpe & zones, whose K3 opens the zones editor
  -- (S.lib.ui_zones, a modal owner); the note pool (kind "pool": E3 steps
  -- S.lib.notes.set_pool, a device setting in notes.data)
  local SETUP_FIELDS = {
    {label = "midi", kind = "param", param_id = "midi_device"},
    {label = "channels", kind = "param", param_id = "midi_channel_mode"},
    {label = "note off", kind = "param", param_id = "midi_note_off"},
    {label = "mpe & zones", kind = "action", hint = "edit", run = function() S.lib.ui_zones.open() end},
    {label = "note pool", kind = "pool"},
    {label = "mutations", kind = "param", param_id = "mutation_enabled"},
    {label = "mutation rate", kind = "param", param_id = "mutation_rate", format = "%.1f s"},
    {label = "mutation prob", kind = "param", param_id = "mutation_probability", format = "%.2f"},
    {label = "mutation amt", kind = "param", param_id = "mutation_amount", format = "%.2f"},
    {label = "save scenes", kind = "action", hint = "save", run = function()
      M.flash(save_scenes_to_disk() and "scenes saved" or "scenes not saved")
    end},
    {label = "load scenes", kind = "action", hint = "load", run = function()
      local outcome = S.lib.scenes.request_load()
      M.flash(SETUP_PAGE.load_texts[outcome],
        outcome == "confirm" and S.lib.scenes.SCENE_LOAD.confirm_seconds or nil)
    end},
    -- 3.4: the patterns follow the clock's transport (lib/sequencer.lua)
    {label = "transport", kind = "param", param_id = "seq_follow_transport", binary = {[0] = "off", [1] = "follow"}},
    -- 3.8: the scale and tuning editor (S.lib.ui_scale_editor, a modal
    -- owner), appended after transport (ruling 44)
    {label = "scale & tuning", kind = "action", hint = "open", run = function() S.lib.ui_scale_editor.open() end},
    -- 3.8: the factory sets' list (S.lib.factory, a modal owner), after
    -- scale & tuning (ruling 44)
    {label = "factory sets", kind = "action", hint = "open", run = function() S.lib.factory.open_list() end},
  }
  M.SETUP_FIELDS = SETUP_FIELDS

  -- What a save or load field's K3 did, on the hint row while SETUP is up,
  -- for seconds (HEADER.flash_seconds when nil); nil text ends the flash
  function M.flash(text, seconds)
    S.lib.ui_flash.start("hints", text, seconds, UI_PAGES.index.SETUP)
  end

  -- The performance setting's fields (kind "performance": E3 steps key's
  -- choices in S.lib.performance.PERFORMANCE)
  local PERFORMANCE_FIELD = {label = "performance", kind = "performance", key = "performance"}
  local BUFFER_FIELD = {label = "buffer length", kind = "performance", key = "buffer_seconds"}

  S.setup_cursor = 1      -- a row index into setup_rows(), always a field
  -- rows the view is scrolled past the cursor's own: E2 on the last field
  -- scrolls on over the status rows below it (#319)
  local setup_view = {tail = 0}

  -- The connected grids' count and the sizes' rows: each size in port
  -- order, followed by "no layout" when Strata has no layout for it (#931:
  -- such a grid is dark and its keys do nothing), as many on a row as end
  -- by x value_right
  local function connected_grids()
    local count, rows = 0, {}
    for port = 1, S.MAX_GRID_PORTS do
      local grid_port = S.grids[port]
      if grid_port and grid_port.device then
        count = count + 1
        local size = grid_port.cols .. "x" .. grid_port.rows
        if not S.lib.grid_core.layout_of(port) then size = size .. SETUP_PAGE.no_layout end
        local joined = rows[#rows] and (rows[#rows] .. " " .. size)
        if joined and screen.text_extents(joined) <= SETUP_PAGE.value_right then
          rows[#rows] = joined
        else
          rows[#rows + 1] = size
        end
      end
    end
    return count, rows
  end

  local function note_row(text)
    return {selectable = false, text = text, dim = true, indent = SETUP_PAGE.note_indent}
  end

  -- The performance fields, then their dim note rows (below both fields, so
  -- the view, which keeps one row above the cursor, always shows the
  -- performance field above the buffer length): "(next start)" when a
  -- shown field differs from the setting this start used (the engine read
  -- the same file at alloc), "may xrun" for high on a CM3 or Pi 3, and the
  -- step-down ("300 s -> 120 s (memory)", or "(meminfo)") when the high tier runs
  -- shorter buffers than the unchanged setting asks for. The buffer length
  -- is offered when the setting or the running tier is high
  local function add_performance_rows(rows)
    local performance = S.lib.performance
    local setting = performance.setting()
    local start = S.performance_start_setting or setting
    local running = S.performance
    local buffer_shown = setting.performance == "high" or running.tier == "high"
    table.insert(rows, PERFORMANCE_FIELD)
    if buffer_shown then table.insert(rows, BUFFER_FIELD) end
    local notes = {}
    if setting.performance ~= start.performance
      or (buffer_shown and setting.buffer_seconds ~= start.buffer_seconds) then
      table.insert(notes, "(next start)")
    end
    if setting.performance == "high" and SETUP_PAGE.xrun_platforms[norns.platform] then
      table.insert(notes, SETUP_PAGE.xrun_note)
    end
    if #notes > 0 then table.insert(rows, note_row(table.concat(notes, ", "))) end
    if buffer_shown and running.tier == "high" and setting.buffer_seconds == start.buffer_seconds
      and running.buffer_seconds < setting.buffer_seconds then
      table.insert(rows, note_row(string.format("%d s -> %d s (%s)", setting.buffer_seconds,
        running.buffer_seconds, performance.step_down_cause())))
    end
  end

  -- 3.9 (#895): a row (and its note row) for every other data file with a
  -- problem, as S.lib.data_files.problems() lists them (the live
  -- gestures.data, a PSET's side file, grids.data, ...; never the scenes'
  -- or buffers' file, whose records are their own), in problems()' order:
  -- "<name> unreadable, kept" (it could not be parsed) or "<name> set
  -- aside" (it parsed and its reader set it aside) and "as <backup>";
  -- "<name> file unreadable" or "<name> file not moved" and "left in
  -- place"; "<name> file not saved". The name is the file's without
  -- ".data", cut to fit the row
  local function add_other_file_rows(rows)
    local texts, text = SETUP_PAGE.file_texts, S.lib.ui_text
    for _, entry in ipairs(S.lib.data_files.problems()) do
      local name = entry.file:match("[^/]*$"):gsub(SETUP_PAGE.data_suffix, "")
      local parsed = entry.problem == "set aside"
      local suffix, note
      if entry.problem == "not saved" then
        suffix = texts["not saved"]
      elseif entry.backup then
        suffix, note = parsed and texts.set_aside or texts.kept, texts.kept_note .. entry.backup:match("[^/]*$")
      else
        suffix, note = parsed and texts.not_moved or texts.unreadable, texts.left_note
      end
      local room = SETUP_PAGE.value_right - screen.text_extents(suffix)
      local shown = text.fit_text(name, room):gsub("%s+$", "")  -- no space left at the cut
      table.insert(rows, {selectable = false, text = shown .. suffix})
      if note then
        table.insert(rows, note_row(text.fit_text(note, SETUP_PAGE.value_right - SETUP_PAGE.note_indent)))
      end
    end
  end

  -- A row (and its dim note row) per data file with a problem (#463): one
  -- that could not be read, kept under its backup's name or still in place
  -- (not saved over), or one whose last write failed. They end the list,
  -- after the status lines (no row ever appears above a field: the cursor
  -- is a row index); E2 scrolls the view down to them from the last field
  local function add_data_file_rows(rows)
    local texts = SETUP_PAGE.file_texts
    for _, entry in ipairs({{"scenes", S.scene_file}, {"buffers", S.buffer_file}}) do
      local label, state = entry[1], entry[2]
      if state.problem == "unreadable" or state.problem == "older" then
        local older = state.problem == "older"
        local kept, in_place = older and texts.older_kept or texts.kept, older and texts.older or texts.unreadable
        table.insert(rows, {selectable = false, text = label .. (state.backup and kept or in_place)})
        table.insert(rows, note_row(state.backup and (texts.kept_note .. state.backup:match("[^/]*$"))
          or texts.in_place_note))
      elseif state.problem then
        table.insert(rows, {selectable = false, text = label .. texts[state.problem]})
      end
    end
    add_other_file_rows(rows)
  end

  -- The grid ports' rotation fields, one per port, connected or not: a row
  -- never comes or goes above a field (the cursor is a row index)
  local function add_rotation_rows(rows)
    local fields = SETUP_PAGE.rotation_fields
    for port = 1, S.MAX_GRID_PORTS do
      fields[port] = fields[port] or {label = "grid " .. port .. " rotation", kind = "rotation", port = port}
      table.insert(rows, fields[port])
    end
  end

  -- The fields, then the status lines and the data files' problems (no
  -- cursor stops). The sizes line exists only while a grid is connected.
  -- Restored buffers are confirmed by the engine; missing files are
  -- remembered paths not found on start
  function M.setup_rows()
    local rows = {}
    for _, field in ipairs(SETUP_FIELDS) do
      table.insert(rows, field)
      -- on standard a pool above the tier's default may xrun (design §2.5);
      -- the pool changes only under the cursor on its own row, so this
      -- note never moves the field the cursor is on
      if field.kind == "pool" and S.performance.tier == "standard" and S.lib.notes.pool() > NOTE_POOL.standard then
        table.insert(rows, note_row(SETUP_PAGE.xrun_note))
      end
    end
    add_rotation_rows(rows)
    add_performance_rows(rows)
    table.insert(rows, {selectable = false, text = S.performance.tier == "high"
      and string.format("running: high, %d s", S.performance.buffer_seconds) or "running: standard"})
    local running_note = S.lib.performance.running_note()
    if running_note then table.insert(rows, note_row(running_note)) end
    local grid_count, grid_sizes = connected_grids()
    table.insert(rows, {selectable = false, text = "grid: " .. grid_count .. " connected"})
    for _, sizes in ipairs(grid_sizes) do
      table.insert(rows, {selectable = false, text = sizes, dim = true})
    end
    table.insert(rows, {selectable = false, text = "arc: " .. (S.arc_connected and "connected" or "none")})
    local buffers_missing = 0
    for slot = 1, NUM_BUFFERS do
      if S.buffers[slot].missing_path then buffers_missing = buffers_missing + 1 end
    end
    table.insert(rows, {selectable = false, text = buffers_missing > 0
      and ("buffers: " .. S.buffers_restored .. " ok, " .. buffers_missing .. " missing")
      or ("buffers: " .. S.buffers_restored .. " restored")})
    add_data_file_rows(rows)
    return rows
  end
  local setup_rows = M.setup_rows

  local function field_value(field)
    if field.kind == "pool" then return tostring(S.lib.notes.pool()) end
    if field.kind == "rotation" then
      return tostring(S.lib.grid_core.rotation(field.port) * SETUP_PAGE.rotation_degrees)
    end
    if field.kind == "performance" then
      local value = S.lib.performance.setting()[field.key]
      return field.key == "buffer_seconds" and (value .. " s") or value
    end
    if field.format then return string.format(field.format, params:get(field.param_id)) end
    if field.binary then return field.binary[params:get(field.param_id)] end
    if field.param_id == "mutation_enabled" then return params:get(field.param_id) == 1 and "on" or "off" end
    return params:string(field.param_id)
  end

  local function draw_row(row, y, selected, value_right)
    screen.move(row.indent or 0, y)
    if row.selectable == false then
      screen.level(row.dim and 4 or 10)
      screen.text(row.text)
    elseif row.param_id == "midi_device" then
      -- the label, the selected port and its device, or the claim's owner in
      -- parentheses (a controller, a remote grid), cut to end by x value_right
      screen.level(selected and 15 or 4)
      local port = params:get("midi_device")
      local prefix = row.label .. " " .. port .. ": "
      local owner = S.lib.io_ports.owner(util.round(port))
      local name = owner and ("(" .. owner .. ")") or midi_device_name()
      screen.text(prefix .. S.lib.ui_text.fit_text(name, value_right - screen.text_extents(prefix)))
    else
      screen.level(selected and 15 or 4)
      screen.text(row.label)
      if row.kind == "param" or row.kind == "performance" or row.kind == "rotation" or row.kind == "pool" then
        screen.move(value_right, y)
        screen.text_right(field_value(row))
      end
    end
  end

  function redraw_setup()
    local rows = setup_rows()
    S.setup_cursor = field_list.clamp(rows, S.setup_cursor)
    field_list.draw(rows, S.setup_cursor, {visible = SETUP_PAGE.visible, first_y = SETUP_PAGE.first_y,
      spacing = SETUP_PAGE.spacing, value_right = SETUP_PAGE.value_right, tail = setup_view.tail}, draw_row)
  end

  -- The hint row (redraw() draws it after the page). An action row offers
  -- no E3 (it does nothing there). With ALT held no K3 shows (ALT+K3 does
  -- nothing here), and E3 is offered only where it turns finely: the
  -- mutation rate, probability and amount. While the view is scrolled past
  -- the cursor's field (setup_view.tail) E3 edits nothing: it scrolls back
  local function setup_hints(alt_held)
    local field = setup_rows()[S.setup_cursor]
    local kind = field and field.kind
    if setup_view.tail > 0 then return alt_held and "E2:field" or "E2:field E3:back" end
    if alt_held then
      return field and field.format and "E2:field E3:fine" or "E2:field"
    end
    if kind == "action" then return "E2:field K3:" .. field.hint end
    return "E2:field E3:value"
  end

  -- K3 runs the save/load field under the cursor; elsewhere it does nothing
  local function setup_key(n)
    if n == 3 then
      local field = setup_rows()[S.setup_cursor]
      if field and field.kind == "action" then field.run() end
    end
  end

  -- The choice d steps from value in choices (clamped at the ends)
  local function step_choice(choices, value, d)
    local index = 1
    for position, choice in ipairs(choices) do
      if choice == value then index = position end
    end
    return choices[util.clamp(index + d, 1, #choices)]
  end

  -- E3 on a performance field: the next or previous choice, saved at once
  -- (performance.data; the engine applies it at the next start)
  local function step_performance_field(field, d)
    local performance = S.lib.performance
    local choices = field.key == "performance" and performance.PERFORMANCE.choices
      or performance.PERFORMANCE.buffer_choices
    local value = performance.setting()[field.key]
    local stepped = step_choice(choices, value, d)
    if stepped ~= value and not performance.set_setting(field.key, stepped) then
      S.lib.ui_flash.start("hints", "setting not saved", nil, UI_PAGES.index.SETUP)
    end
  end

  -- E3 on a grid port's rotation field: the next or previous quarter turn
  -- (clamped at 0 and 270), saved at once (grids.data) and applied to the
  -- grid on the port
  local function step_rotation_field(field, d)
    local core = S.lib.grid_core
    local rotation = core.rotation(field.port)
    local stepped = util.clamp(rotation + d, 0, core.MAX_ROTATION)
    if stepped ~= rotation and not core.set_rotation(field.port, stepped) then
      S.lib.ui_flash.start("hints", "setting not saved", nil, UI_PAGES.index.SETUP)
    end
  end

  -- E3 on the note pool: one more or fewer (clamped at 0 and
  -- NOTE_POOL.max), saved at once (notes.data, by S.lib.notes.set_pool,
  -- which also tells the engine)
  local function step_pool_field(d)
    local notes = S.lib.notes
    local pool = notes.pool()
    local stepped = util.clamp(pool + d, 0, NOTE_POOL.max)
    if stepped ~= pool and not notes.set_pool(stepped) then
      S.lib.ui_flash.start("hints", "setting not saved", nil, UI_PAGES.index.SETUP)
    end
  end

  -- E2 moves over the fields, E3 edits the one under the cursor. While E2
  -- has scrolled the view on past the last field (#319), the field may be
  -- out of view: E3 then only scrolls back to it, editing nothing
  function setup_enc(n, d)
    if n == 2 then
      S.setup_cursor, setup_view.tail = field_list.move_scroll(setup_rows(), S.setup_cursor,
        setup_view.tail, d, SETUP_PAGE.visible)
    elseif n == 3 and setup_view.tail > 0 then
      setup_view.tail = 0
    elseif n == 3 then
      local field = setup_rows()[S.setup_cursor]
      if field and field.kind == "rotation" then
        step_rotation_field(field, d)
      elseif field and field.kind == "pool" then
        step_pool_field(d)
      elseif field and field.kind == "performance" then
        step_performance_field(field, d)
      elseif field and field.kind == "param" then
        if field.param_id == "mutation_enabled" or field.binary then
          -- a binary has no range for enc_param_delta; set_binary_param
          -- echoes it to a MIDI map (#538)
          set_binary_param(field.param_id, d > 0 and 1 or 0)
        else
          enc_param_delta(n, field.param_id, d)
        end
      end
    end
  end

  local function plug_grids(context)
    context.grid.plug(1, 16, 16)
    context.grid.plug(2, 16, 8)
  end

  -- The zones editor (S.lib.ui_zones) opened from its row, the cursor on
  -- row (an index of its rows) and column (1 zone, 2 low, 3 high); widest:
  -- every voice's zone upper and its range C#-2 (the widest note name), the
  -- bend range 96 st
  local function zones_editor_state(name, row, column, widest, learn)
    return {name = name, setup = function()
      if widest then
        params:set("mpe_bend_range", 96)
        for voice = 1, S.constants.NUM_VOICES do
          params:set("v" .. voice .. "_zone", 3)
          params:set("v" .. voice .. "_zone_low", 1); params:set("v" .. voice .. "_zone_high", 1)
        end
      end
      -- a layout state plays no MIDI: the MIDI module's note tap is a
      -- do-nothing stand-in, so a learn can wait
      if learn then S.lib.midi_in.set_note_tap = function() end end
      S.lib.ui_zones.open()
      enc(2, row - 1)
      for _ = 2, column do key(3, 1); key(3, 0) end
      if learn then S.lib.ui_zones.learn(S.constants.NUM_VOICES) end
      if learn == "high" then S.lib.ui_zones.note(1) end
    end}
  end

  -- The scale and tuning editor (S.lib.ui_scale_editor) opened from its
  -- row, the cursor on row (1 root, 2 scale, 3 notes, 4 tuning), after
  -- prepare: the widest scale name, every class in, the longest built-in, a
  -- long file name (cut by fit_text), 19 equal's --, a pending choice, a
  -- refused file's reason
  local function scale_editor_state(name, row, prepare)
    return {name = name, setup = function()
      -- a layout state plays no MIDI: the note tap is a do-nothing stand-in
      S.lib.midi_in.set_note_tap = function() end
      if prepare then prepare() end
      local editor = S.lib.ui_scale_editor
      editor.open()
      local owner = S.lib.ui_modal.top()
      owner.enc(2, row - 1)
    end}
  end
  local function use_tuning(wanted)
    for _, entry in ipairs(S.lib.tuning.built_ins()) do
      if entry.name == wanted then S.lib.tuning.select(entry) end
    end
  end
  local function tunings_file(file, text)
    local folder = _path.data .. S.lib.tuning.TUNING.folder
    util.make_dir(folder)
    local handle = io.open(folder .. file, "w")
    handle:write(text)
    handle:close()
  end
  local SCALE_EDITOR_STATES = {
    scale_editor_state("scale & tuning editor, root", 1),
    scale_editor_state("scale & tuning editor, the widest scale", 2, function()
      for index, option in ipairs(params:lookup_param("scale").options) do
        if option == "Gagaku Rittsu Sen Pou" then params:set("scale", index) end
      end
    end),
    scale_editor_state("scale & tuning editor, every class in", 3),
    scale_editor_state("scale & tuning editor, the longest tuning", 4, function() use_tuning("meantone 1/4") end),
    scale_editor_state("scale & tuning editor, a long file name", 4, function()
      tunings_file("a very long tuning file name for the editor.scl", "Long\n1\n2/1\n")
      -- its name as load_file gives it (cut to name_max), wider than the row
      local entry = S.lib.tuning.load_file("a very long tuning file name for the editor.scl")
      if entry then S.lib.tuning.select(entry) end
    end),
    scale_editor_state("scale & tuning editor, a non-ASCII file name", 4, function()
      tunings_file("caf\195\169 \195\188ber tuning.scl", "Cafe\n1\n2/1\n")
      local entry = S.lib.tuning.load_file("caf\195\169 \195\188ber tuning.scl")
      if entry then S.lib.tuning.select(entry) end
    end),
    scale_editor_state("scale & tuning editor, 19 equal", 3, function() use_tuning("19 equal") end),
    {name = "scale & tuning editor, a pending choice", setup = function()
      S.lib.midi_in.set_note_tap = function() end
      S.lib.ui_scale_editor.open()
      local owner = S.lib.ui_modal.top()
      owner.enc(2, 3); owner.enc(3, 1)
    end},
    {name = "scale & tuning editor, a refused file", setup = function()
      S.lib.midi_in.set_note_tap = function() end
      tunings_file("broken.scl", "Broken\n0\n")
      S.lib.ui_scale_editor.open()
      local owner = S.lib.ui_modal.top()
      owner.enc(2, 3); owner.enc(3, 100); owner.key(3, 1)
    end},
  }

  -- The factory sets list (S.lib.factory, a modal owner) opened from its
  -- row, over an index of sets written to the script's folder first (none:
  -- no index); with a set's files, a load can start
  local function factory_index(sets, with_files)
    local folder = norns.state.path .. S.lib.factory.FACTORY.folder
    util.make_dir(folder)
    S.lib.data_files.write(folder .. S.lib.factory.FACTORY.index,
      {version = S.lib.factory.FACTORY.index_version, sets = sets})
    if not with_files then return end
    for _, set in ipairs(sets) do
      local set_folder = folder .. set.key .. "/"
      util.make_dir(set_folder)
      local handle = io.open(set_folder .. S.lib.factory.FACTORY.params_file, "w")
      handle:write("-- " .. set.name .. "\n")
      handle:close()
      S.lib.data_files.write(set_folder .. S.lib.factory.FACTORY.samples_file,
        {version = S.lib.factory.FACTORY.set_version, files = {}})
    end
  end
  local FACTORY_SETS = {{key = "glass", name = "MMMMMMMMMMMM", version = 12}, {key = "dusk", name = "dusk", version = 1}}
  local FACTORY_LIST_STATES = {
    {name = "the factory sets row", setup = function()
      enc(2, -20)
      while setup_rows()[S.setup_cursor].label ~= "factory sets" do enc(2, 1) end
    end},
    {name = "factory sets list, none", setup = function() S.lib.factory.open_list() end},
    {name = "factory sets list, a twelve-character name and v12", setup = function()
      factory_index(FACTORY_SETS)
      S.lib.factory.open_list()
    end},
    {name = "factory sets list, the armed prompt", setup = function()
      factory_index(FACTORY_SETS, true)
      S.scene_file.unsaved = true
      S.lib.factory.open_list()
      S.lib.ui_modal.top().key(3, 1)
    end},
    {name = "factory sets list, a set loading and a second load refused", setup = function()
      factory_index(FACTORY_SETS, true)
      S.lib.factory.open_list()
      local owner = S.lib.ui_modal.top()
      owner.key(3, 1)
      owner.key(3, 1)
    end},
  }

  -- The page's record, at SETUP's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. It has no arc
  -- fields: the rings stay dark on SETUP. Each layout state's setup runs on a
  -- fresh script before the layout checks
  S.registry.pages[UI_PAGES.index.SETUP] = {name = "SETUP", draw = redraw_setup, hints = setup_hints,
    enc = setup_enc, key = setup_key,
    layout_states = {
      {name = "scrolled to the start", setup = function() enc(2, -20) end},
      {name = "scrolled to the end", setup = function() enc(2, 20) end},
      {name = "two grids scrolled to the end", setup = function(context)
        plug_grids(context); context.arc.plug(1); enc(2, 20)
      end},
      {name = "data files unreadable", setup = function()
        S.scene_file.problem, S.scene_file.backup = "unreadable", "/x/scenes.data.bak.2"
        S.buffer_file.problem, S.buffer_file.backup = "unreadable", "/x/buffers.data.bak.9"
        enc(2, 60)
      end},
      {name = "scenes file older", setup = function()
        S.scene_file.problem, S.scene_file.backup = "older", "/x/scenes.data.bak.2"
        enc(2, 60)
      end},
      {name = "data files not saved", setup = function()
        S.scene_file.problem, S.buffer_file.problem = "not saved", "unreadable"; enc(2, 20)
      end},
      {name = "load prompt", setup = function()
        enc(2, 10)  -- load scenes
        M.flash(SETUP_PAGE.load_texts.confirm, S.lib.scenes.SCENE_LOAD.confirm_seconds)
      end},
      {name = "data files unreadable, high setting with notes", setup = function()
        norns.platform = 2
        S.performance = {tier = "high", buffer_seconds = 120, max_grains = 128, history_seconds = 60,
          reason = "high: setting"}
        S.performance_setting = {performance = "high", buffer_seconds = 300}
        S.performance_start_setting = {performance = "high", buffer_seconds = 300}
        S.scene_file.problem, S.scene_file.backup = "unreadable", "/x/scenes.data.bak"
        S.buffer_file.problem = "not saved"
        enc(2, 60)
      end},
      -- 3.9 (#895): the other data files' rows, through the reader, the
      -- set-aside and the writer: a damaged gestures.data kept, a PSET's
      -- side file with a long name in place, a write that failed
      {name = "other data files' problems", setup = function()
        local data_files, folder = S.lib.data_files, S.lib.scenes.scene_data_dir
        util.make_dir(folder)
        for _, file in ipairs({"gestures.data", "a very long preset name.sequences.data"}) do
          local handle = io.open(folder .. file, "w")
          handle:write("return {")
          handle:close()
          data_files.read(folder .. file)
        end
        data_files.set_aside(folder .. "gestures.data", ".bak")
        data_files.write(folder .. "missing folder/matrix.data", {version = 1})
        -- one that parsed and was set aside by its reader: set aside
        local handle = io.open(folder .. "voices.data", "w")
        handle:write(data_files.encode({version = 1}))
        handle:close()
        data_files.read(folder .. "voices.data")
        data_files.set_aside(folder .. "voices.data", ".bak")
        enc(2, 60)
      end},
      -- 3.9 (#931): four grids, two of sizes with no layout
      {name = "grids with no layout", setup = function(context)
        context.grid.plug(1, 10, 10); context.grid.plug(2, 16, 16)
        context.grid.plug(3, 12, 6); context.grid.plug(4, 8, 8)
        enc(2, 60)
      end},
      {name = "a 16x8 turned upright, the rotation fields", setup = function(context)
        context.grid.plug(1, 16, 8); S.lib.grid_core.set_rotation(1, 1); enc(2, 13)
      end},
      {name = "buffers missing", setup = function()
        S.buffers[1].missing_path = "/x/a.wav"; S.buffers[2].missing_path = "/x/b.wav"
        S.buffers_restored = 6; enc(2, 20)
      end},
      {name = "long MIDI device", setup = function(context)
        context.midi.plug(1, "Very Long Manufacturer Name USB MIDI Interface Port 1")
      end},
      {name = "performance: standard", setup = function() enc(2, 20) end},
      {name = "performance: high setting, standard tier on a CM3", setup = function()
        norns.platform = 2
        S.performance_setting = {performance = "high", buffer_seconds = 300}
        enc(2, 20)
      end},
      {name = "performance: memory step-down", setup = function()
        S.performance = {tier = "high", buffer_seconds = 120, max_grains = 128, history_seconds = 60,
          reason = "high: setting"}
        S.performance_setting = {performance = "high", buffer_seconds = 300}
        S.performance_start_setting = {performance = "high", buffer_seconds = 300}
        enc(2, 20)
      end},
      {name = "performance: memory step-down, no meminfo", setup = function()
        S.performance = {tier = "high", buffer_seconds = 16, max_grains = 128, history_seconds = 60,
          reason = "high: setting; buffer 300 s -> 16 s (meminfo unreadable)"}
        S.performance_setting = {performance = "high", buffer_seconds = 300}
        S.performance_start_setting = {performance = "high", buffer_seconds = 300}
        enc(2, 20)
      end},
      -- 3.5: the note pool at its maximum on standard (may xrun), and the
      -- zones editor
      {name = "note pool at its maximum on standard", setup = function()
        enc(2, 4); enc(3, NOTE_POOL.max)
      end},
      zones_editor_state("mpe & zones editor", 1, 1),
      zones_editor_state("mpe & zones editor, v7's high at its widest", 3 + S.constants.NUM_VOICES, 3, true),
      zones_editor_state("mpe & zones editor, learning v7's low", 3 + S.constants.NUM_VOICES, 2, true, "low"),
      zones_editor_state("mpe & zones editor, learning v7's high", 3 + S.constants.NUM_VOICES, 3, true, "high"),
      SCALE_EDITOR_STATES[1], SCALE_EDITOR_STATES[2], SCALE_EDITOR_STATES[3], SCALE_EDITOR_STATES[4],
      SCALE_EDITOR_STATES[5], SCALE_EDITOR_STATES[6], SCALE_EDITOR_STATES[7], SCALE_EDITOR_STATES[8],
      SCALE_EDITOR_STATES[9],
      FACTORY_LIST_STATES[1], FACTORY_LIST_STATES[2], FACTORY_LIST_STATES[3], FACTORY_LIST_STATES[4],
      FACTORY_LIST_STATES[5],
      {name = "performance: active file not written", setup = function()
        S.performance = {tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
          reason = "standard: performance_active.data could not be written"}
        enc(2, 20)
      end},
    }}

  return M
end

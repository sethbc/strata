-- lib/pages/setup.lua
-- The SETUP page: a field list (MIDI port, channel mode, mutations on/off,
-- rate, probability, amount, save scenes, load scenes, each grid port's
-- rotation, the performance setting and its buffer length) with the status
-- lines (the running tier,
-- grids, arc, buffers) below it; E2 moves the cursor, E3 edits the field's
-- value, K3 runs a save/load field. It scrolls like FX
-- (S.lib.ui_field_list). The performance fields edit the setting
-- (S.lib.performance), the rotation fields S.lib.grid_core's, not params.
-- Registers its S.registry.pages record.
-- The functions that were global stay global.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local UI_PAGES = S.constants.UI_PAGES
  local field_list = S.lib.ui_field_list

  local SETUP_PAGE = {
    visible = 6,          -- rows at y 18-53, 7 px apart (a descender clears the next row, #422), clear of the hint row
    first_y = 18,
    spacing = 7,
    value_right = 124,    -- the scroll marker owns x 127
    note_indent = 8,      -- a field's dim note row ("(next start)", ...) starts here
    xrun_platforms = {[2] = true, [3] = true},  -- norns.platform: CM3, Pi 3 (matron's platform.h)
    -- the hint row's flash for each answer of S.lib.scenes.request_load
    load_texts = {loaded = "scenes loaded", missing = "no scenes file", unreadable = "scenes unreadable",
      confirm = "K3 again: drop unsaved"},
    -- the status rows for a data file with a problem (S.scene_file,
    -- S.buffer_file), after its label ("scenes", "buffers"): kept, a file
    -- that could not be read and was moved to the backup the note row names;
    -- unreadable, one still in place, which is not saved over; not saved, a
    -- write that failed
    file_texts = {kept = " unreadable, kept", unreadable = " file unreadable", ["not saved"] = " file not saved",
      kept_note = "as ", in_place_note = "not saved over"},
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
  -- scene of this session is not on disk (#328)
  local SETUP_FIELDS = {
    {label = "midi", kind = "param", param_id = "midi_device"},
    {label = "channels", kind = "param", param_id = "midi_channel_mode"},
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

  -- The connected grids' count and sizes, in port order
  local function connected_grids()
    local count, sizes = 0, {}
    for port = 1, S.MAX_GRID_PORTS do
      local grid_port = S.grids[port]
      if grid_port and grid_port.device then
        count = count + 1
        table.insert(sizes, grid_port.cols .. "x" .. grid_port.rows)
      end
    end
    return count, sizes
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
      table.insert(notes, "may xrun")
    end
    if #notes > 0 then table.insert(rows, note_row(table.concat(notes, ", "))) end
    if buffer_shown and running.tier == "high" and setting.buffer_seconds == start.buffer_seconds
      and running.buffer_seconds < setting.buffer_seconds then
      table.insert(rows, note_row(string.format("%d s -> %d s (%s)", setting.buffer_seconds,
        running.buffer_seconds, performance.step_down_cause())))
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
      if state.problem == "unreadable" then
        table.insert(rows, {selectable = false, text = label .. (state.backup and texts.kept or texts.unreadable)})
        table.insert(rows, note_row(state.backup and (texts.kept_note .. state.backup:match("[^/]*$"))
          or texts.in_place_note))
      elseif state.problem then
        table.insert(rows, {selectable = false, text = label .. texts[state.problem]})
      end
    end
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
    for _, field in ipairs(SETUP_FIELDS) do table.insert(rows, field) end
    add_rotation_rows(rows)
    add_performance_rows(rows)
    table.insert(rows, {selectable = false, text = S.performance.tier == "high"
      and string.format("running: high, %d s", S.performance.buffer_seconds) or "running: standard"})
    local running_note = S.lib.performance.running_note()
    if running_note then table.insert(rows, note_row(running_note)) end
    local grid_count, grid_sizes = connected_grids()
    table.insert(rows, {selectable = false, text = "grid: " .. grid_count .. " connected"})
    if grid_count > 0 then
      table.insert(rows, {selectable = false, text = table.concat(grid_sizes, " "), dim = true})
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
    if field.kind == "rotation" then
      return tostring(S.lib.grid_core.rotation(field.port) * SETUP_PAGE.rotation_degrees)
    end
    if field.kind == "performance" then
      local value = S.lib.performance.setting()[field.key]
      return field.key == "buffer_seconds" and (value .. " s") or value
    end
    if field.format then return string.format(field.format, params:get(field.param_id)) end
    if field.param_id == "mutation_enabled" then return params:get(field.param_id) == 1 and "on" or "off" end
    return params:string(field.param_id)
  end

  local function draw_row(row, y, selected, value_right)
    screen.move(row.indent or 0, y)
    if row.selectable == false then
      screen.level(row.dim and 4 or 10)
      screen.text(row.text)
    elseif row.param_id == "midi_device" then
      -- the label, the selected port and its device, cut to end by x value_right
      screen.level(selected and 15 or 4)
      local prefix = row.label .. " " .. params:get("midi_device") .. ": "
      screen.text(prefix .. S.lib.ui_text.fit_text(midi_device_name(), value_right - screen.text_extents(prefix)))
    else
      screen.level(selected and 15 or 4)
      screen.text(row.label)
      if row.kind == "param" or row.kind == "performance" or row.kind == "rotation" then
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
      elseif field and field.kind == "performance" then
        step_performance_field(field, d)
      elseif field and field.kind == "param" then
        if field.param_id == "mutation_enabled" then
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
      {name = "data files not saved", setup = function()
        S.scene_file.problem, S.buffer_file.problem = "not saved", "unreadable"; enc(2, 20)
      end},
      {name = "load prompt", setup = function()
        enc(2, 7)  -- load scenes
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
      {name = "a 16x8 turned upright, the rotation fields", setup = function(context)
        context.grid.plug(1, 16, 8); S.lib.grid_core.set_rotation(1, 1); enc(2, 8)
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
      {name = "performance: active file not written", setup = function()
        S.performance = {tier = "standard", buffer_seconds = 16, max_grains = 128, history_seconds = 16,
          reason = "standard: performance_active.data could not be written"}
        enc(2, 20)
      end},
    }}

  return M
end

-- lib/pages/setup.lua
-- The SETUP page: a field list (MIDI port, channel mode, mutations on/off,
-- rate, probability, amount, save scenes, load scenes, the performance
-- setting and its buffer length) with the status lines (the running tier,
-- grids, arc, buffers) below it; E2 moves the cursor, E3 edits the field's
-- value, K3 runs a save/load field. It scrolls like FX
-- (S.lib.ui_field_list). The performance fields edit the setting
-- (S.lib.performance), not params. Registers its S.registry.pages record.
-- The functions that were global stay global.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local UI_PAGES = S.constants.UI_PAGES
  local field_list = S.lib.ui_field_list

  local SETUP_PAGE = {
    visible = 7,          -- rows at y 18-54, 6 px apart, clear of the hint row
    first_y = 18,
    spacing = 6,
    value_right = 124,    -- the scroll marker owns x 127
    note_indent = 8,      -- a field's dim note row ("(next start)", ...) starts here
    xrun_platforms = {[2] = true, [3] = true},  -- norns.platform: CM3, Pi 3 (matron's platform.h)
  }

  -- The fields, in cursor order. Each row starts with its label. kind
  -- "param": E3 edits param_id, shown with format (a string.format pattern,
  -- or the param's own string); the MIDI port's row reads "<label> <port>:
  -- <device>". kind "action": K3 calls run and hint names the K3 hint (run
  -- looks the scenes function up as it runs, so a test can stand in for it)
  local SETUP_FIELDS = {
    {label = "midi", kind = "param", param_id = "midi_device"},
    {label = "channels", kind = "param", param_id = "midi_channel_mode"},
    {label = "mutations", kind = "param", param_id = "mutation_enabled"},
    {label = "mutation rate", kind = "param", param_id = "mutation_rate", format = "%.1f s"},
    {label = "mutation prob", kind = "param", param_id = "mutation_probability", format = "%.2f"},
    {label = "mutation amt", kind = "param", param_id = "mutation_amount", format = "%.2f"},
    {label = "save scenes", kind = "action", run = function() save_scenes_to_disk() end, hint = "save"},
    {label = "load scenes", kind = "action", run = function() load_scenes_from_disk() end, hint = "load"},
  }
  M.SETUP_FIELDS = SETUP_FIELDS

  -- The performance setting's fields (kind "performance": E3 steps key's
  -- choices in S.lib.performance.PERFORMANCE)
  local PERFORMANCE_FIELD = {label = "performance", kind = "performance", key = "performance"}
  local BUFFER_FIELD = {label = "buffer length", kind = "performance", key = "buffer_seconds"}

  S.setup_cursor = 1      -- a row index into setup_rows(), always a field

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
  -- memory step-down ("300 s -> 120 s (memory)") when the high tier runs
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
      table.insert(rows, note_row(string.format("%d s -> %d s (memory)", setting.buffer_seconds,
        running.buffer_seconds)))
    end
  end

  -- The fields, then the status lines (no cursor stops). The sizes line
  -- exists only while a grid is connected. Restored buffers are confirmed by
  -- the engine; missing files are remembered paths not found on start
  function M.setup_rows()
    local rows = {}
    for _, field in ipairs(SETUP_FIELDS) do table.insert(rows, field) end
    add_performance_rows(rows)
    table.insert(rows, {selectable = false, text = S.performance.tier == "high"
      and string.format("running: high, %d s", S.performance.buffer_seconds) or "running: standard"})
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
    return rows
  end
  local setup_rows = M.setup_rows

  local function field_value(field)
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
      if row.kind == "param" or row.kind == "performance" then
        screen.move(value_right, y)
        screen.text_right(field_value(row))
      end
    end
  end

  function redraw_setup()
    local rows = setup_rows()
    S.setup_cursor = field_list.clamp(rows, S.setup_cursor)
    field_list.draw(rows, S.setup_cursor, {visible = SETUP_PAGE.visible, first_y = SETUP_PAGE.first_y,
      spacing = SETUP_PAGE.spacing, value_right = SETUP_PAGE.value_right}, draw_row)
  end

  -- The hint row (redraw() draws it after the page)
  local function setup_hints(alt_held)
    local field = setup_rows()[S.setup_cursor]
    local hints = "E2:field E3:value"
    if field and field.hint then hints = hints .. " K3:" .. field.hint end
    return hints
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
    if stepped ~= value then performance.set_setting(field.key, stepped) end
  end

  -- E2 moves over the fields, E3 edits the one under the cursor
  function setup_enc(n, d)
    if n == 2 then
      S.setup_cursor = field_list.move(setup_rows(), S.setup_cursor, d)
    elseif n == 3 then
      local field = setup_rows()[S.setup_cursor]
      if field and field.kind == "performance" then
        step_performance_field(field, d)
      elseif field and field.kind == "param" then
        if field.param_id == "mutation_enabled" then
          params:set(field.param_id, d > 0 and 1 or 0)  -- a binary has no range for enc_param_delta
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
    }}

  return M
end

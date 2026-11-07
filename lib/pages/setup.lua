-- lib/pages/setup.lua
-- The SETUP page: a field list (MIDI port, channel mode, mutations on/off,
-- rate, probability, amount, save scenes, load scenes) with the status lines
-- (grids, arc, buffers) below it; E2 moves the cursor, E3 edits the field's
-- value, K3 runs a save/load field. It scrolls like FX
-- (S.lib.ui_field_list). Registers its S.registry.pages record. The
-- functions that were global stay global.

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
  }

  -- The fields, in cursor order. kind "param": E3 edits param_id, shown with
  -- format (a string.format pattern, or the param's own string); kind
  -- "action": K3 calls the named global function and hint names the K3 hint
  local SETUP_FIELDS = {
    {label = "midi port", kind = "param", param_id = "midi_device"},
    {label = "channels", kind = "param", param_id = "midi_channel_mode"},
    {label = "mutations", kind = "param", param_id = "mutation_enabled"},
    {label = "mutation rate", kind = "param", param_id = "mutation_rate", format = "%.1f s"},
    {label = "mutation prob", kind = "param", param_id = "mutation_probability", format = "%.2f"},
    {label = "mutation amt", kind = "param", param_id = "mutation_amount", format = "%.2f"},
    {label = "save scenes", kind = "action", action = "save_scenes_to_disk", hint = "save"},
    {label = "load scenes", kind = "action", action = "load_scenes_from_disk", hint = "load"},
  }
  M.SETUP_FIELDS = SETUP_FIELDS

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

  -- The fields, then the status lines (no cursor stops). The sizes line
  -- exists only while a grid is connected. Restored buffers are confirmed by
  -- the engine; missing files are remembered paths not found on start
  local function setup_rows()
    local rows = {}
    for _, field in ipairs(SETUP_FIELDS) do table.insert(rows, field) end
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

  local function field_value(field)
    if field.format then return string.format(field.format, params:get(field.param_id)) end
    if field.param_id == "mutation_enabled" then return params:get(field.param_id) == 1 and "on" or "off" end
    return params:string(field.param_id)
  end

  local function draw_row(row, y, selected, value_right)
    screen.move(0, y)
    if row.selectable == false then
      screen.level(row.dim and 4 or 10)
      screen.text(row.text)
    elseif row.param_id == "midi_device" then
      -- the selected port and its device, cut to end by x value_right
      screen.level(selected and 15 or 4)
      local prefix = "midi " .. params:get("midi_device") .. ": "
      screen.text(prefix .. S.lib.ui_text.fit_text(midi_device_name(), value_right - screen.text_extents(prefix)))
    else
      screen.level(selected and 15 or 4)
      screen.text(row.label)
      if row.kind == "param" then
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
    local field = SETUP_FIELDS[S.setup_cursor]
    local hints = "E2:field E3:value"
    if field and field.hint then hints = hints .. " K3:" .. field.hint end
    return hints
  end

  -- K3 runs the save/load field under the cursor; elsewhere it does nothing
  local function setup_key(n)
    if n == 3 then
      local field = SETUP_FIELDS[S.setup_cursor]
      if field and field.kind == "action" then _G[field.action]() end
    end
  end

  -- E2 moves over the fields, E3 edits the one under the cursor
  function setup_enc(n, d)
    if n == 2 then
      S.setup_cursor = field_list.move(setup_rows(), S.setup_cursor, d)
    elseif n == 3 then
      local field = SETUP_FIELDS[S.setup_cursor]
      if field and field.kind == "param" then
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
    }}

  return M
end

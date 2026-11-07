-- lib/grid/core.lua
-- The grids Strata drives (S.grids, one vport per port) and what every
-- layout shares: the grid UI state (S.grid_page, S.param_page,
-- S.grid_voice_select), the 256's GRID_LAYOUT geometry
-- (S.lib.grid_core.GRID_LAYOUT), attaching vports, hot-plug, voice
-- selection and the dispatch of key presses and redraws to the layout
-- records in S.registry.grid_layouts (lib/grid/layout_256.lua, ...), chosen
-- by each grid's exact size. The functions that were global stay global,
-- defined here.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  -- Grid devices (support multiple grids); SETUP counts S.MAX_GRID_PORTS
  S.MAX_GRID_PORTS = 4
  S.grids = {}

  -- Grid UI state
  S.grid_page = 1  -- 1=patterns, 2=parameters, 3=scenes, 4=buffers/fx (256 only)
  S.param_page = 1
  S.grid_voice_select = 1

  -- Grid functions
  local GRID_LAYOUT = {
    fader_rows = 4,         -- 256-grid parameter page: one fader per row 9-12
    fader_width = 16,       -- fader columns
    fader_first_row = 9,
    param_page_row = 13,
    -- 256-grid BUFFER / FX page (page 4): record (row 1) and clear (row 2)
    -- per buffer slot, one FX fader per row 3-7, one source row per voice 9-15
    buffer_record_row = 1,
    buffer_clear_row = 2,
    fx_fader_ids = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"},
    fx_first_row = 3,
    source_first_row = 9    -- voice v's row is 8 + v; column = source option (1 synth, 2-9 buffers, 10 input)
  }
  -- lib/grid/faders.lua and lib/grid/layout_256.lua alias it
  M.GRID_LAYOUT = GRID_LAYOUT

  -- Pick a grid's layout by its exact size. 16x16 must be matched exactly or
  -- an 8x16 grid (rows == 16) would be treated as a 256. The name is the
  -- layout's key in S.registry.grid_layouts; nil (no layout) for other sizes.
  local function grid_layout(grid_port)
    local cols, rows = grid_port.cols, grid_port.rows
    if cols == 16 and rows == 16 then
      return "256"
    elseif cols == 16 and rows == 8 then
      return "128h"
    elseif cols == 8 and rows == 16 then
      return "128v"
    elseif cols == 8 and rows == 8 then
      return "64"
    end
    return nil
  end

  -- Store a grid port's vport and route its key events to grid_key. Handlers
  -- live on the vport only: norns fires both device.key and vports[port].key,
  -- so also setting them on the device would run grid_key twice per press.
  local function attach_grid(port)
    local grid_port = grid.connect(port)
    S.grids[port] = grid_port
    grid_port.key = function(x, y, z)
      grid_key(port, x, y, z)
    end
    return grid_port
  end

  function grid_init()
    -- Connect up to 4 grids
    for port = 1, S.MAX_GRID_PORTS do
      if grid.connect(port).device then
        local grid_port = attach_grid(port)
        print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
      end
    end
    grid_redraw()
  end

  -- Hot-plug. norns passes the raw device here; store its port's vport (as
  -- grid_init does) rather than the device, which has no .device field.
  function grid.add(device)
    local port = device.port
    if not port then return end  -- device not assigned to a grid port
    local grid_port = attach_grid(port)
    print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
    grid_redraw()
    request_redraw()  -- SETUP lists the connected grids
  end

  function grid.remove(device)
    local port = device.port
    if not port then return end
    if S.grids[port] then
      S.grids[port].key = nil
      S.grids[port] = nil
    end
    request_redraw()
    print("grid " .. port .. " disconnected")
  end

  function grid_key(port, x, y, z)
    if z == 0 then return end  -- Only respond to key presses

    local grid_port = S.grids[port]
    if not grid_port then return end

    local layout = S.registry.grid_layouts[grid_layout(grid_port)]
    if layout then
      layout.key(x, y, z)
    end

    grid_redraw()
    request_redraw()
  end

  function select_grid_voice(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    S.grid_voice_select = voice_idx
    S.param_page = util.clamp(S.param_page, 1, fader_page_count(voice_idx))
  end

  function grid_redraw()
    if next(S.grids) == nil then return end  -- no grids: nothing to do

    for _, grid_port in pairs(S.grids) do
      if grid_port.device then
        local layout = S.registry.grid_layouts[grid_layout(grid_port)]

        grid_port:all(0)

        if layout then
          layout.redraw(grid_port)
        end

        grid_port:refresh()
      end
    end
  end

  -- Leave every connected grid dark on exit
  S.register_cleanup(S.constants.CLEANUP_ORDER.grids_dark, function()
    for _, grid_port in pairs(S.grids) do
      grid_port:all(0)
      grid_port:refresh()
    end
  end)

  return M
end

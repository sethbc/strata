-- lib/pages/setup.lua
-- The SETUP page: connected grids and arc, saved scenes, restored buffers,
-- the MIDI port and channel mode; E2 MIDI port, E3 channel mode, K3 save
-- scenes. Registers its S.registry.pages record. The functions that were
-- global stay global.

return function(S)
  local M = {}
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local UI_PAGES = S.constants.UI_PAGES

  function redraw_setup()
    -- Connected grids (count, then sizes in port order)
    local grid_count = 0
    local grid_sizes = {}
    for port = 1, S.MAX_GRID_PORTS do
      local grid_port = S.grids[port]
      if grid_port and grid_port.device then
        grid_count = grid_count + 1
        table.insert(grid_sizes, grid_port.cols .. "x" .. grid_port.rows)
      end
    end

    local scenes_saved = 0
    for scene_num = 1, NUM_SCENES do
      if S.scenes[scene_num].populated then scenes_saved = scenes_saved + 1 end
    end

    -- rows 6 px apart (like the BUFFER page), leaving y 54 above the hints
    screen.level(10)
    screen.move(0, 18)
    screen.text("grid: " .. grid_count .. " connected")
    screen.level(4)
    screen.move(0, 24)
    screen.text(table.concat(grid_sizes, " "))
    screen.level(10)
    screen.move(0, 30)
    screen.text("arc: " .. (S.arc_connected and "connected" or "none"))
    screen.move(0, 36)
    screen.text("scenes: " .. scenes_saved .. "/" .. NUM_SCENES .. " saved")
    -- restored = confirmed by the engine; missing files are remembered paths
    -- not found on start ("restored" becomes "ok" to fit beside them)
    local buffers_missing = 0
    for slot = 1, NUM_BUFFERS do
      if S.buffers[slot].missing_path then buffers_missing = buffers_missing + 1 end
    end
    screen.move(0, 42)
    if buffers_missing > 0 then
      screen.text("buffers: " .. S.buffers_restored .. " ok, " .. buffers_missing .. " missing")
    else
      screen.text("buffers: " .. S.buffers_restored .. " restored")
    end
    -- the selected MIDI port and its device (cut to the screen width), then the channel mode
    local midi_prefix = "midi " .. params:get("midi_device") .. ": "
    screen.move(0, 48)
    screen.text(midi_prefix .. S.lib.ui_text.fit_text(midi_device_name(), 127 - screen.text_extents(midi_prefix)))
    screen.level(4)
    screen.move(0, 54)
    screen.text("ch: " .. params:string("midi_channel_mode"))
  end

  -- The hint row (redraw() draws it after the page)
  local function setup_hints(alt_held)
    return "E2:port E3:ch K3:save"
  end

  local function setup_key(n)
    if n == 3 then
      save_scenes_to_disk()
    end
  end

  -- SETUP E2: MIDI port, E3: channel mode
  function setup_enc(n, d)
    if n == 2 then
      enc_param_delta(n, "midi_device", d)
    elseif n == 3 then
      enc_param_delta(n, "midi_channel_mode", d)
    end
  end

  -- The page's record, at SETUP's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. It has no arc
  -- fields: the rings stay dark on SETUP
  S.registry.pages[UI_PAGES.index.SETUP] = {name = "SETUP", draw = redraw_setup, hints = setup_hints,
    enc = setup_enc, key = setup_key}

  return M
end

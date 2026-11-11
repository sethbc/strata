-- lib/grid/core.lua
-- The grids Strata drives (S.grids, one vport per port) and what every
-- layout shares: the grid UI state (each port's page, S.param_page,
-- S.grid_voice_select), the 256's GRID_LAYOUT geometry
-- (S.lib.grid_core.GRID_LAYOUT), attaching vports, hot-plug, voice
-- selection, each port's held keys and holds (S.grid_held), the step-level
-- and scene-save gestures, the key helpers the layouts share, and the
-- dispatch of key presses, releases and redraws to the layout records in
-- S.registry.grid_layouts (lib/grid/layout_256.lua, ...), chosen by each
-- grid's exact size. The functions that were global stay global, defined
-- here.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local GRID_HOLD = S.constants.GRID_HOLD

  -- Grid devices (support multiple grids); SETUP counts S.MAX_GRID_PORTS
  S.MAX_GRID_PORTS = 4
  S.grids = {}

  -- Grid UI state. Each port shows its own page (M.page): 1 patterns,
  -- 2 parameters, 3 scenes, 4 buffers (the 256 adds FX faders), 5 positions
  local MAX_GRID_PAGES = 5
  S.grid_pages = {}
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

  local function whole_number_in(value, low, high)
    return type(value) == "number" and value >= low and value <= high and value % 1 == 0
  end

  -- Pages per port: page(port) is 1 until set_page gives the port another
  function M.page(port)
    return S.grid_pages[port] or 1
  end

  function M.set_page(port, page)
    if not whole_number_in(port, 1, S.MAX_GRID_PORTS) then return end
    if not whole_number_in(page, 1, MAX_GRID_PAGES) then return end
    S.grid_pages[port] = page
  end

  -- Whether any connected grid shows the page (redraw only when one does)
  function M.any_page(page)
    for port, grid_port in pairs(S.grids) do
      if grid_port.device and M.page(port) == page then return true end
    end
    return false
  end

  -- Held keys, per port: S.grid_held[port][x][y] = press time (util.time()),
  -- set on press and cleared on release, on the port's grid.remove and in
  -- cleanup. Private to this module, per port and key: the pending hold
  -- clocks (hold_clocks), the consumed keys (consumed_keys), the step keys
  -- the step-level gesture sees (step_keys: {voice, step, order, level_key})
  -- and each port's layout state (port_states)
  S.grid_held = {}
  local hold_clocks = {}
  local consumed_keys = {}
  local step_keys = {}
  local port_states = {}
  local press_count = 0  -- orders presses made at the same util.time()

  -- tables[port][x][y], or nil
  local function key_value(tables, port, x, y)
    local columns = tables[port]
    local rows = columns and columns[x]
    return rows and rows[y]
  end

  -- tables[port][x][y] = value, creating the inner tables (nil clears)
  local function set_key_value(tables, port, x, y, value)
    if value == nil and key_value(tables, port, x, y) == nil then return end
    tables[port] = tables[port] or {}
    tables[port][x] = tables[port][x] or {}
    tables[port][x][y] = value
  end

  function M.held(port, x, y)
    return key_value(S.grid_held, port, x, y)
  end

  function M.hold_pending(port, x, y)
    return key_value(hold_clocks, port, x, y) ~= nil
  end

  -- A consumed key's release does nothing (cleared after that release)
  function M.consume(port, x, y)
    if M.held(port, x, y) == nil then return end
    set_key_value(consumed_keys, port, x, y, true)
  end

  function M.consumed(port, x, y)
    return key_value(consumed_keys, port, x, y) == true
  end

  -- Per-port layout state (a 64's shown half, a 256's clipboard, ...),
  -- emptied when the port's grid is removed
  function M.port_state(port)
    port_states[port] = port_states[port] or {}
    return port_states[port]
  end

  -- The port's layout state if it has one, else nil: reads without
  -- creating it (an invariant, a check for a port whose grid left)
  function M.existing_port_state(port)
    return port_states[port]
  end

  local function cancel_hold(port, x, y)
    local clock_id = key_value(hold_clocks, port, x, y)
    if clock_id == nil then return end
    clock.cancel(clock_id)
    set_key_value(hold_clocks, port, x, y, nil)
  end

  -- Run fn once if the key (held now) is still held after `seconds`. Its
  -- release, the port's grid.remove and cleanup cancel it
  function M.on_hold(port, x, y, seconds, fn)
    if M.held(port, x, y) == nil then return end
    cancel_hold(port, x, y)
    local clock_id
    clock_id = clock.run(function()
      clock.sleep(seconds)
      if key_value(hold_clocks, port, x, y) ~= clock_id then return end
      set_key_value(hold_clocks, port, x, y, nil)
      fn()
    end)
    set_key_value(hold_clocks, port, x, y, clock_id)
  end

  -- Forget a port's keys: pending holds (canceled), held, consumed and step
  -- keys, its layout state and its page
  local function forget_port(port)
    for _, rows in pairs(hold_clocks[port] or {}) do
      for _, clock_id in pairs(rows) do clock.cancel(clock_id) end
    end
    hold_clocks[port] = nil
    S.grid_held[port] = {}
    consumed_keys[port] = nil
    step_keys[port] = nil
    port_states[port] = nil
    S.grid_pages[port] = nil
  end

  local function press_key(port, x, y)
    press_count = press_count + 1
    -- a press with no release before it (a missed event) starts over
    cancel_hold(port, x, y)
    set_key_value(consumed_keys, port, x, y, nil)
    set_key_value(step_keys, port, x, y, nil)
    set_key_value(S.grid_held, port, x, y, util.time())
  end

  local function release_key(port, x, y)
    set_key_value(S.grid_held, port, x, y, nil)
    set_key_value(consumed_keys, port, x, y, nil)
    set_key_value(step_keys, port, x, y, nil)
  end

  -- A step's level from a key's position along the voice's shown steps
  function M.level_for_position(position, positions)
    local level = math.max(1, util.round(position * MAX_STEP_LEVEL / positions))
    return math.min(level, MAX_STEP_LEVEL)
  end

  -- The most recently pressed step key of the voice held on this port, other
  -- than (x, y) and keys that set a level: its entry and coordinates, or nil
  local function latest_held_step(port, voice_idx, x, y)
    local latest, latest_x, latest_y
    for key_x, rows in pairs(step_keys[port] or {}) do
      for key_y, entry in pairs(rows) do
        if entry.voice == voice_idx and not entry.level_key and not (key_x == x and key_y == y)
          and M.held(port, key_x, key_y) ~= nil and (latest == nil or entry.order > latest.order) then
          latest, latest_x, latest_y = entry, key_x, key_y
        end
      end
    end
    return latest, latest_x, latest_y
  end

  -- A pattern key. The step toggles at press, unless another step key of the
  -- same voice is held on this port: then the most recently pressed of those
  -- gets this key's level (its position, 1..positions, along the voice's
  -- shown steps) and both keys are consumed. Releases do nothing. A voice,
  -- step or position out of range does nothing, so only valid steps are
  -- ever recorded as held (and later take a level)
  function M.step_key(port, x, y, z, voice_idx, step, position, positions)
    if z ~= 1 then return end
    if not whole_number_in(voice_idx, 1, NUM_VOICES) or not whole_number_in(step, 1, PATTERN_LENGTH) then return end
    if not whole_number_in(positions, 1, PATTERN_LENGTH) or not whole_number_in(position, 1, positions) then return end
    local held_step, held_x, held_y = latest_held_step(port, voice_idx, x, y)
    if held_step then
      S.patterns[voice_idx][held_step.step] = M.level_for_position(position, positions)
      M.consume(port, x, y)
      M.consume(port, held_x, held_y)
      set_key_value(step_keys, port, x, y, {voice = voice_idx, step = step, order = press_count, level_key = true})
      return
    end
    toggle_pattern_step(voice_idx, step)
    set_key_value(step_keys, port, x, y, {voice = voice_idx, step = step, order = press_count})
  end

  -- End the step-level gesture on voice_idx's held step keys, on every port:
  -- S.lib.sequencer.replace_pattern (every whole-pattern change: clear,
  -- randomize, a 256's paste, a scene recall) calls it, so a step held from
  -- before never takes a level in the new pattern. The keys stay held; their
  -- releases do nothing, as always, and the next step key of the voice
  -- toggles its own step
  function M.end_step_gestures(voice_idx)
    for _, columns in pairs(step_keys) do
      for _, rows in pairs(columns) do
        for key_y, entry in pairs(rows) do
          if entry.voice == voice_idx then rows[key_y] = nil end
        end
      end
    end
  end

  -- End the step-level gesture on every step key held on one port, whatever
  -- the voice: a 64's half switch calls it, so a step held in the half no
  -- longer shown never takes a level. The keys stay held; their releases do
  -- nothing. A port that is not a whole number in 1..S.MAX_GRID_PORTS does
  -- nothing
  function M.end_port_step_gestures(port)
    if not whole_number_in(port, 1, S.MAX_GRID_PORTS) then return end
    step_keys[port] = nil
  end

  -- A scene save key: saves once held GRID_HOLD.scene_save_seconds (layouts
  -- light it at 15 while hold_pending)
  function M.scene_save_key(port, x, y, z, scene_num)
    if z ~= 1 then return end
    M.on_hold(port, x, y, GRID_HOLD.scene_save_seconds, function()
      S.lib.scenes.save(scene_num)
    end)
  end

  local function valid_source(voice_idx, option)
    return whole_number_in(voice_idx, 1, NUM_VOICES) and whole_number_in(option, 1, #SOURCE_OPTIONS)
  end

  -- A source key: option 1 synth, 2-9 buffers 1-8, 10 input
  function M.source_key(voice_idx, option)
    if not valid_source(voice_idx, option) then return end
    params:set("v" .. voice_idx .. "_source", option)
  end

  -- 15 the selected source, 2 a free buffer (S.lib.buffers.is_free), 4 any other
  function M.source_level(voice_idx, option)
    if not valid_source(voice_idx, option) then return 0 end
    if option == S.voices[voice_idx].source then return 15 end
    if S.lib.buffers.is_free(option - SOURCE_SYNTH) then return 2 end
    return 4
  end

  -- A record key records into the slot, or stops its recording early
  function M.record_key(slot)
    if whole_number_in(slot, 1, NUM_BUFFERS) then record_buffer(slot) end
  end

  function M.clear_key(slot)
    if whole_number_in(slot, 1, NUM_BUFFERS) then clear_buffer(slot) end
  end

  -- From the slot's status (S.lib.buffers.status), the answer source_level
  -- shares: 11 armed (waiting to start), 15 recording or finishing, 2 free
  -- (S.lib.buffers.is_free), 8 anything else (loading, loaded, a named load
  -- the engine has not reported yet)
  local RECORD_LEVELS = {armed = 11, recording = 15, dub = 15, loop = 15, finishing = 15}
  function M.record_level(slot)
    if not whole_number_in(slot, 1, NUM_BUFFERS) then return 0 end
    local level = RECORD_LEVELS[S.lib.buffers.status(slot)]
    if level then return level end
    return S.lib.buffers.is_free(slot) and 2 or 8
  end

  M.CLEAR_LEVEL = 4

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

  -- The layout record of the grid connected to a port ({key, redraw,
  -- fx_faders_page?, selects_grid_voice?}), or nil (no grid, or a size with
  -- no layout)
  function M.layout_of(port)
    local grid_port = S.grids[port]
    return grid_port and S.registry.grid_layouts[grid_layout(grid_port)] or nil
  end

  -- Whether a connected grid shows the FX faders now: its layout record's
  -- fx_faders_page (the 256's page 4; the other layouts have none) is the
  -- port's page. The FX params' actions redraw the grids only then
  function M.any_fx_faders()
    for port, grid_port in pairs(S.grids) do
      local layout = grid_port.device and S.registry.grid_layouts[grid_layout(grid_port)]
      if layout and layout.fx_faders_page == M.page(port) then return true end
    end
    return false
  end

  -- Per attached port, the device its vport held when attached (reconcile_ports)
  local attached_devices = {}

  -- Store a grid port's vport and route its key events to grid_key. Handlers
  -- live on the vport only: norns fires both device.key and vports[port].key,
  -- so also setting them on the device would run grid_key twice per press.
  local function attach_grid(port)
    local grid_port = grid.connect(port)
    S.grids[port] = grid_port
    attached_devices[port] = grid_port.device
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
  -- A grid plugged in starts with no held keys, on page 1.
  function grid.add(device)
    local port = device.port
    if not port then return end  -- device not assigned to a grid port
    forget_port(port)
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
    attached_devices[port] = nil
    -- its pending holds never fire (no scene save from a removed grid)
    forget_port(port)
    request_redraw()
    print("grid " .. port .. " disconnected")
  end

  -- SYSTEM > DEVICES moves a grid to another port through norns'
  -- update_devices() alone (lua/core/menu/devices.lua): no grid.add, no
  -- grid.remove. Run as the norns menu closes: a vport holding a device that
  -- is not attached, or another device than the one attached, is forgotten
  -- and attached, as grid.add does; an attached port whose vport is empty is
  -- detached and forgotten, as grid.remove does
  function M.reconcile_ports()
    for port = 1, S.MAX_GRID_PORTS do
      local grid_port = grid.connect(port)
      local attached = S.grids[port]
      if grid_port.device and (attached == nil or attached_devices[port] ~= grid_port.device) then
        forget_port(port)
        attach_grid(port)
        print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
      elseif attached and grid_port.device == nil then
        attached.key = nil
        S.grids[port] = nil
        attached_devices[port] = nil
        forget_port(port)
        print("grid " .. port .. " disconnected")
      end
    end
    grid_redraw()
    request_redraw()  -- SETUP lists the connected grids
  end

  S.register_menu_close(function() M.reconcile_ports() end)

  -- While grid_key handles a key, grid_redraw() calls from its actions (a
  -- param action that redraws, toggle_voice, ...) only wait: grid_key
  -- paints each grid once when the key is handled (#161)
  local key_repaint = {handling = false}

  local function handle_key(port, grid_port, x, y, z)
    local layout = S.registry.grid_layouts[grid_layout(grid_port)]
    if z == 1 then
      press_key(port, x, y)
      if layout then layout.key(port, x, y, 1) end
    else
      cancel_hold(port, x, y)
      if layout and not M.consumed(port, x, y) then layout.key(port, x, y, 0) end
      release_key(port, x, y)
    end
  end

  -- Presses and releases. A press is held (S.grid_held) before the layout
  -- sees it. A release cancels the key's hold, reaches the layout unless the
  -- key was consumed, then forgets the key. Layouts get key(port, x, y, z)
  -- and return on z == 0 unless they handle releases. One repaint per key,
  -- also when the handler fails (its error is raised after the repaint)
  function grid_key(port, x, y, z)
    local grid_port = S.grids[port]
    if not grid_port then return end
    if x < 1 or x > grid_port.cols or y < 1 or y > grid_port.rows then return end

    key_repaint.handling = true
    local handled, key_error = xpcall(handle_key, debug.traceback, port, grid_port, x, y, z)
    key_repaint.handling = false

    grid_redraw()
    request_redraw()
    if not handled then error(key_error, 0) end
  end

  function select_grid_voice(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    S.grid_voice_select = voice_idx
    S.param_page = util.clamp(S.param_page, 1, fader_page_count(voice_idx))
  end

  function grid_redraw()
    if next(S.grids) == nil then return end  -- no grids: nothing to do
    if key_repaint.handling then return end  -- grid_key paints once the key is handled

    for port, grid_port in pairs(S.grids) do
      if grid_port.device then
        local layout = S.registry.grid_layouts[grid_layout(grid_port)]

        grid_port:all(0)

        if layout then
          layout.redraw(port, grid_port)
        end

        grid_port:refresh()
      end
    end
  end

  -- Connect the grids at init
  S.register_start(S.constants.START_ORDER.grids, function()
    grid_init()
  end)

  -- On exit cancel every pending hold (no scene save during cleanup), forget
  -- the held keys and leave every connected grid dark
  S.register_cleanup(S.constants.CLEANUP_ORDER.grids_dark, function()
    for port = 1, S.MAX_GRID_PORTS do forget_port(port) end
    for _, grid_port in pairs(S.grids) do
      grid_port:all(0)
      grid_port:refresh()
    end
  end)

  -- Only a held key is consumed or waits for a hold; a port has an attached
  -- device recorded exactly while it is attached
  S.register_invariant("grid keys", function()
    for port = 1, S.MAX_GRID_PORTS do
      if (S.grids[port] ~= nil) ~= (attached_devices[port] ~= nil) then
        return "grid " .. port .. (S.grids[port] and " is attached with no device recorded"
          or " is not attached but has a device recorded")
      end
    end
    for kind, tables in pairs({consumed = consumed_keys, ["hold pending"] = hold_clocks}) do
      for port, columns in pairs(tables) do
        for x, rows in pairs(columns) do
          for y in pairs(rows) do
            if M.held(port, x, y) == nil then
              return "grid " .. port .. " key " .. x .. "," .. y .. " is " .. kind .. " but not held"
            end
          end
        end
      end
    end
  end)

  return M
end

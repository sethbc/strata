-- lib/grid/pane.lua
-- 3.8's pane engine (design §10.1-§10.2): a grid is one or two panes, each
-- showing one of the grid pages (S.registry.grid_pages, a record per file
-- under lib/grid/pages/), with a strip of fixed keys. The arranger
-- (M.arrange) turns a layout's spec (where each pane sits, turned or
-- halved, and its strip) into the layout record the core dispatches to;
-- the pane object it hands a page takes and draws keys in pane
-- coordinates (x 1-16 along a line, y 1-7 the lines); the strips, the
-- 64's chooser and fader lines (a page's faders(pane)) are the engine's
-- own keys, which a page never sees. M.signature() is what the drift
-- tick's follow compares (S.lib.grid_faders.follow_faders)

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local GRID_PAGES = S.constants.GRID_PAGES
  local GRID_HOLD = S.constants.GRID_HOLD
  local grid_core = S.lib.grid_core
  local LEVELS = grid_core.LEVELS

  -- A pane is NUM_VOICES lines of `width` keys (a pattern's steps); its
  -- strip is the line after them in the pane coordinates the harness and
  -- M.physical use; a 64 shows half_width columns (its own) of it at a
  -- time. The strip keys' and the chooser's levels; a fader line's bar
  -- and value. A page's state is kept in port_state(port)[pages_key]
  local PANE = {
    width = S.constants.PATTERN_LENGTH, half_width = 8, strip_line = NUM_VOICES + 1, pages_key = "pages",
    levels = {fill_on = 15, fill_off = 4, tempo_held = 15, tempo_idle = 4, muted = 15, unmuted = 4,
      chooser_shown = 15, choice_shown = 15, choice_other = 4, dark = 0, bar = 8, value = 15},
    -- the 64's chooser: row r of column c (page c) picks side and half
    chooser_rows = {{side = 1, half = 1}, {side = 1, half = 2}, {side = 2, half = 1}, {side = 2, half = 2}},
  }

  -- The strips (design §10.2), as key names, key 1 first: the upper strip
  -- (the 128h's row 8, the 256's row 8, the 128v's column 8), the lower
  -- (the 256's row 16) and the small (the 64's row 8)
  local function strip_of(first, second, voice_kind)
    local keys = {first, second}
    for page = 1, GRID_PAGES.count do keys[#keys + 1] = "page " .. page end
    for voice_idx = 1, NUM_VOICES do keys[#keys + 1] = voice_kind .. " " .. voice_idx end
    return keys
  end
  M.STRIPS = {upper = strip_of("play", "fill", "voice"), lower = strip_of("tempo -", "tempo +", "mute"),
    small = {"chooser"}}
  for voice_idx = 1, NUM_VOICES do M.STRIPS.small[#M.STRIPS.small + 1] = "voice " .. voice_idx end

  -- Each strip key name's action: {kind, n}
  local KEY_ACTIONS = {play = {kind = "play"}, fill = {kind = "fill"}, chooser = {kind = "chooser"},
    ["tempo -"] = {kind = "tempo", n = -1}, ["tempo +"] = {kind = "tempo", n = 1}}
  for page = 1, GRID_PAGES.count do KEY_ACTIONS["page " .. page] = {kind = "page", n = page} end
  for voice_idx = 1, NUM_VOICES do
    KEY_ACTIONS["voice " .. voice_idx] = {kind = "voice", n = voice_idx}
    KEY_ACTIONS["mute " .. voice_idx] = {kind = "mute", n = voice_idx}
  end

  -- The geometry of every layout record arrange made, by the record
  local geometries = setmetatable({}, {__mode = "k"})

  local function pane_offset(geometry, half)
    return geometry.half and (half - 1) * PANE.half_width or 0
  end

  local function pane_width(geometry)
    return geometry.half and PANE.half_width or PANE.width
  end

  -- The physical key of pane key (x, y) of pane `index` on a layout with
  -- this geometry, its half `half`: y 1..NUM_VOICES a line, y strip_line
  -- the pane's strip (x its key). nil for a key the layout does not show
  local function physical_of(geometry, index, x, y, half)
    local spec = geometry.panes[index]
    if spec == nil or type(x) ~= "number" or type(y) ~= "number" or x % 1 ~= 0 or y % 1 ~= 0 then return nil end
    if y == PANE.strip_line then
      local strip = spec.strip
      if x < 1 or x > #M.STRIPS[strip.keys] then return nil end
      if strip.column then return strip.column, x end
      return x, strip.row
    end
    if y < 1 or y > NUM_VOICES or x < 1 or x > PANE.width then return nil end
    if geometry.turned then return y, x end
    local offset = pane_offset(geometry, half or 1)
    if x <= offset or x > offset + pane_width(geometry) then return nil end
    return x - offset + (spec.x or 0), y + (spec.y or 0)
  end

  -- What a physical key is: {strip = name, pane = index} for a strip key,
  -- {pane = index, x, y} (pane coordinates) for a pane key, nil for none
  local function locate(geometry, px, py, half)
    for index, spec in ipairs(geometry.panes) do
      local strip = spec.strip
      local keys = M.STRIPS[strip.keys]
      local key = (strip.column and px == strip.column and py) or (strip.row and py == strip.row and px)
      if key then return keys[key] and {strip = keys[key], pane = index} or nil end
    end
    if geometry.turned then
      if px >= 1 and px <= NUM_VOICES and py >= 1 and py <= PANE.width then return {pane = 1, x = py, y = px} end
      return nil
    end
    for index, spec in ipairs(geometry.panes) do
      local x, y = px - (spec.x or 0), py - (spec.y or 0)
      if y >= 1 and y <= NUM_VOICES and x >= 1 and x <= pane_width(geometry) then
        return {pane = index, x = x + pane_offset(geometry, half), y = y}
      end
    end
    return nil
  end

  -- The physical key of a pane key on a layout record (the test harness's
  -- way to a key): see physical_of
  function M.physical(layout, index, x, y, half)
    local geometry = geometries[layout]
    if geometry == nil then return nil end
    return physical_of(geometry, index, x, y, half)
  end

  -- The pane object a page's press and redraw get: what the pane shows and
  -- the core's key helpers in pane coordinates
  local function pane_object(geometry, port, index)
    local half = geometry.half and grid_core.half(port, index) or 1
    local offset, width = pane_offset(geometry, half), pane_width(geometry)
    local pane = {port = port, index = index, page = grid_core.page(port, index), side = grid_core.side(port, index),
      width = width, offset = offset, turned = geometry.turned == true}
    local function at(x, y) return physical_of(geometry, index, x, y, half) end
    function pane.shows(x) return type(x) == "number" and x > offset and x <= offset + width end
    -- the page's per-port state, port_state(port).pages[name] (never a
    -- key of port_state itself, where lib/positions.lua keeps its record)
    function pane.state()
      local name = GRID_PAGES.names[pane.page]
      local port_state = grid_core.port_state(port)
      port_state[PANE.pages_key] = port_state[PANE.pages_key] or {}
      local pages = port_state[PANE.pages_key]
      pages[name] = pages[name] or {}
      return pages[name]
    end
    -- the core's helper fn at the physical key of (x, y), or nil off the pane
    local function wrap(fn)
      return function(x, y, ...)
        if type(y) ~= "number" or y < 1 or y > NUM_VOICES then return nil end
        local px, py = at(x, y)
        if px == nil then return nil end
        return fn(port, px, py, ...)
      end
    end
    pane.held, pane.hold_pending = wrap(grid_core.held), wrap(grid_core.hold_pending)
    pane.on_hold, pane.consume, pane.consumed = wrap(grid_core.on_hold), wrap(grid_core.consume), wrap(grid_core.consumed)
    pane.press_as, pane.pressed_as = wrap(grid_core.press_as), wrap(grid_core.pressed_as)
    pane.gesture_key = wrap(grid_core.gesture_key)
    -- a pattern key: position x - offset of the width shown, so a level
    -- follows 16 keys, or 8 on a half
    function pane.step_key(x, y, z, voice_idx, step)
      if type(y) ~= "number" or y < 1 or y > NUM_VOICES then return end
      local px, py = at(x, y)
      if px == nil then return end
      grid_core.step_key(port, px, py, z, voice_idx, step, x - offset, width)
    end
    return pane
  end

  -- A page's fader lines as the pane shows them: {y, id, keys (shown),
  -- x_of = fn(k) -> pane x}. A line that fits the shown columns is drawn
  -- as it is (upward on a turned pane); one wider than a half is drawn
  -- across the half's keys; any other is not shown
  local function read_lines(record, pane)
    local lines = {}
    for _, line in ipairs(record.faders(pane) or {}) do
      local first, keys = line.first, line.keys
      local last = first + keys - 1
      local entry
      if first > pane.offset and last <= pane.offset + pane.width then
        entry = {y = line.line, id = line.id, keys = keys, x_of = function(k)
          if pane.turned then return first + keys - k end
          return first + k - 1
        end}
      elseif keys > pane.width then
        entry = {y = line.line, id = line.id, keys = pane.width, x_of = function(k) return pane.offset + k end}
      end
      lines[#lines + 1] = entry
    end
    return lines
  end

  -- Per port and pane ("<port>:<pane>"): the faders and signature errors
  -- last printed (each page function runs contained, as its redraw does)
  local fader_errors, signature_errors = {}, {}

  -- The page's fader lines, read contained: a faders(pane) that raises
  -- prints once and the pane has no fader lines (its keys reach the page)
  local function shown_lines(record, pane)
    if record.faders == nil then return {} end
    local lines = {}
    S.lib.ui_frame.contained_call(fader_errors, pane.port .. ":" .. pane.index, "grid page faders", function()
      lines = read_lines(record, pane)
    end)
    return lines
  end

  -- The key's place k along a shown fader line, or nil off it
  local function place_on(line, x, y)
    if y ~= line.y then return nil end
    for k = 1, line.keys do
      if line.x_of(k) == x then return k end
    end
    return nil
  end

  local function draw_line(line, led)
    local position = fader_position(line.id, line.keys)
    for k = 1, position - 1 do led(line.x_of(k), line.y, PANE.levels.bar) end
    led(line.x_of(position), line.y, PANE.levels.value)
  end

  -- The 64's chooser, per port (forgotten with the port's state)
  local function chooser_shown(port)
    local state = grid_core.existing_port_state(port)
    return state ~= nil and state.chooser == true
  end

  local function chooser_choice(port, px, py)
    local record = S.registry.grid_pages[px]
    local choice = PANE.chooser_rows[py]
    if px > GRID_PAGES.count or choice == nil or record == nil then return nil end
    if choice.side == 2 and (record.sides or 1) ~= 2 then return nil end
    return px, choice
  end

  -- A chooser key: its press picks page, side and half at once (the
  -- pane's keys end); every chooser key is consumed, so its release does
  -- nothing
  local function chooser_key(port, px, py, z)
    if z ~= 1 then return end
    local page, choice = chooser_choice(port, px, py)
    if page then
      grid_core.set_page(port, page, 1, choice.side)
      grid_core.set_half(port, 1, choice.half)
    end
    grid_core.consume(port, px, py)
  end

  local function draw_chooser(port, device)
    for page = 1, GRID_PAGES.count do
      for row, choice in ipairs(PANE.chooser_rows) do
        local level = PANE.levels.dark
        if chooser_choice(port, page, row) then
          local shown = grid_core.page(port, 1) == page and grid_core.side(port, 1) == choice.side
            and grid_core.half(port, 1) == choice.half
          level = shown and PANE.levels.choice_shown or PANE.levels.choice_other
        end
        device:led(page, row, level)
      end
    end
  end

  -- A tempo key: a press steps the tempo by n and flashes it; held, it
  -- steps again after tempo_repeat_delay and every tempo_repeat_seconds
  -- (an on_hold that arms itself again), until its release
  local function tempo_key(port, px, py, n)
    local function step()
      params:delta("tempo", n)
      header_flash(string.format("tempo %d", util.round(S.lib.params_setup.clock_tempo_now())))
    end
    local function again()
      step()
      grid_core.on_hold(port, px, py, GRID_HOLD.tempo_repeat_seconds, again)
    end
    step()
    grid_core.on_hold(port, px, py, GRID_HOLD.tempo_repeat_delay, again)
  end

  -- A page key: a page with no record does nothing; another page shows on
  -- the key's pane; the shown page's key shows its next side, if any
  local function page_key(port, pane, page)
    local record = S.registry.grid_pages[page]
    if record == nil then return end
    if grid_core.page(port, pane) ~= page then
      grid_core.set_page(port, page, pane, 1)
    elseif (record.sides or 1) == 2 then
      grid_core.set_page(port, page, pane, grid_core.side(port, pane) % 2 + 1)
    end
  end

  -- NV (the 64's chooser key): a press arms the chooser's hold; a release
  -- before it plays or stops, after it closes the chooser
  local function chooser_strip_key(port, px, py, z)
    if z == 1 then
      grid_core.press_as(port, px, py, "chooser")
      grid_core.on_hold(port, px, py, GRID_HOLD.chooser_seconds, function()
        grid_core.port_state(port).chooser = true
        grid_core.end_pane_keys(port, 1)
        grid_redraw()
      end)
    elseif chooser_shown(port) then
      grid_core.port_state(port).chooser = nil
    elseif grid_core.pressed_as(port, px, py, "chooser") then
      pattern_toggle()
    end
  end

  -- A strip key (presses and releases): design §10.2's table
  local function strip_key(port, pane, name, px, py, z)
    local action = KEY_ACTIONS[name]
    if action.kind == "fill" then
      local holder = "grid:" .. port
      if z == 1 then
        grid_core.press_as(port, px, py, "fill")
        S.lib.conditions.hold_fill(holder, true, function() return grid_core.pressed_as(port, px, py, "fill") end)
      else
        S.lib.conditions.hold_fill(holder, false)
      end
    elseif action.kind == "chooser" then
      chooser_strip_key(port, px, py, z)
    elseif z ~= 1 then
      return
    elseif action.kind == "play" then
      pattern_toggle()
    elseif action.kind == "page" then
      page_key(port, pane, action.n)
    elseif action.kind == "voice" then
      toggle_voice(action.n)
    elseif action.kind == "tempo" then
      tempo_key(port, px, py, action.n)
    elseif action.kind == "mute" then
      local id = "v" .. action.n .. "_mute"
      set_binary_param(id, params:get(id) == 1 and 0 or 1)
    end
  end

  local function strip_level(port, pane, name, px, py)
    local action = KEY_ACTIONS[name]
    local levels = PANE.levels
    if action.kind == "play" then return grid_core.play_level() end
    if action.kind == "fill" then return S.lib.conditions.fill() and levels.fill_on or levels.fill_off end
    if action.kind == "chooser" then
      return chooser_shown(port) and levels.chooser_shown or grid_core.play_level()
    end
    if action.kind == "voice" then return grid_core.voice_level(action.n) end
    if action.kind == "tempo" then
      return grid_core.held(port, px, py) ~= nil and levels.tempo_held or levels.tempo_idle
    end
    if action.kind == "mute" then
      return params:get("v" .. action.n .. "_mute") == 1 and levels.muted or levels.unmuted
    end
    -- a page key
    if S.registry.grid_pages[action.n] == nil then return levels.dark end
    if grid_core.page(port, pane) ~= action.n then return LEVELS.page_other end
    return grid_core.side(port, pane) == 2 and LEVELS.side_two or LEVELS.page_shown
  end

  -- A physical key (the layout record's key): the strip; else, on a 64
  -- while the chooser shows, the chooser; else a fader line; else the
  -- page's press. A pane on a page with no record takes no keys
  local function take_key(geometry, port, px, py, z)
    local hit = locate(geometry, px, py, grid_core.half(port, 1))
    if hit == nil then return end
    if hit.strip then
      strip_key(port, hit.pane, hit.strip, px, py, z)
      return
    end
    if geometry.half and chooser_shown(port) then
      chooser_key(port, px, py, z)
      return
    end
    local pane = pane_object(geometry, port, hit.pane)
    local record = S.registry.grid_pages[pane.page]
    if record == nil then return end
    for _, line in ipairs(shown_lines(record, pane)) do
      local k = place_on(line, hit.x, hit.y)
      if k then
        if z == 1 then set_param_from_column(line.id, k, line.keys) end
        return
      end
    end
    record.press(pane, hit.x, hit.y, z)
  end

  -- Per port and pane ("<port>:<pane>"): the redraw error last printed
  local redraw_errors = {}

  local function draw_page(record, pane, led)
    record.redraw(pane, led)
    for _, line in ipairs(shown_lines(record, pane)) do draw_line(line, led) end
  end

  -- The layout record's redraw: each pane (its page, contained per pane, or
  -- the 64's chooser) and its strip
  local function draw_grid(geometry, port, device)
    for index, spec in ipairs(geometry.panes) do
      local pane = pane_object(geometry, port, index)
      local half = geometry.half and grid_core.half(port, index) or 1
      if geometry.half and chooser_shown(port) then
        draw_chooser(port, device)
      else
        local record = S.registry.grid_pages[pane.page]
        if record then
          local function led(x, y, level)
            if type(y) ~= "number" or y < 1 or y > NUM_VOICES then return end
            local px, py = physical_of(geometry, index, x, y, half)
            if px then device:led(px, py, level) end
          end
          S.lib.ui_frame.contained_call(redraw_errors, port .. ":" .. index, "grid page redraw", draw_page,
            record, pane, led)
        end
      end
      for n, name in ipairs(M.STRIPS[spec.strip.keys]) do
        local px, py = physical_of(geometry, index, n, PANE.strip_line, half)
        device:led(px, py, strip_level(port, index, name, px, py))
      end
    end
  end

  -- A layout record from a spec: {panes = {{x, y, strip = {row | column,
  -- keys = "upper" | "lower" | "small"}}, ...}, turned (the 128v: pane x
  -- is the row, y the column), half (the 64: a half of a pane at a time),
  -- start = {page per pane} (patterns where absent)}. The record is
  -- {key, redraw, panes, pane_at = fn(x, y) -> pane index or nil (a strip
  -- key, no key), start_pages}
  function M.arrange(spec)
    local geometry = {panes = spec.panes, turned = spec.turned == true, half = spec.half == true}
    local start_pages = {}
    for index = 1, #spec.panes do start_pages[index] = spec.start and spec.start[index] or GRID_PAGES.patterns end
    local record = {panes = #spec.panes, start_pages = start_pages}
    record.key = function(port, x, y, z) take_key(geometry, port, x, y, z) end
    record.redraw = function(port, device) draw_grid(geometry, port, device) end
    record.pane_at = function(x, y)
      local hit = locate(geometry, x, y, 1)
      return hit and not hit.strip and hit.pane or nil
    end
    geometries[record] = geometry
    return record
  end

  -- What the drift tick follows (S.lib.grid_faders.follow_faders): for
  -- each pane of each connected grid whose page has fader lines or a
  -- signature, its view, its shown lines' positions and the page's
  -- signature, as one string; nil when no pane has any
  function M.signature()
    local ports = {}
    for port, grid_port in pairs(S.grids) do
      if grid_port.device then ports[#ports + 1] = port end
    end
    table.sort(ports)
    local parts = {}
    for _, port in ipairs(ports) do
      local layout = grid_core.layout_of(port)
      local geometry = layout and geometries[layout]
      for index = 1, geometry and #geometry.panes or 0 do
        local pane = pane_object(geometry, port, index)
        local record = S.registry.grid_pages[pane.page]
        if record and (record.faders or record.signature) then
          -- contained per pane: a signature that raises prints once and
          -- reads as unchanged, so the drift tick goes on
          local part = {grid_core.view(port, index)}
          local read = S.lib.ui_frame.contained_call(signature_errors, port .. ":" .. index, "grid page signature",
            function()
              for _, line in ipairs(shown_lines(record, pane)) do part[#part + 1] = fader_position(line.id, line.keys) end
              if record.signature then part[#part + 1] = tostring(record.signature(pane)) end
            end)
          if not read then part = {grid_core.view(port, index), "?"} end
          parts[#parts + 1] = port .. "=" .. table.concat(part, ",")
        end
      end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "|")
  end

  return M
end

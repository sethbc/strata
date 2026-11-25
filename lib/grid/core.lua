-- lib/grid/core.lua
-- The grids Strata drives (S.grids, one vport per port) and what every
-- layout shares: the grid UI state (each port's panes, S.grid_panes, and
-- S.param_page, S.grid_voice_select), the faders' GRID_LAYOUT
-- (S.lib.grid_core.GRID_LAYOUT), attaching vports, hot-plug, voice
-- selection, each port's held keys and holds (S.grid_held) and their end
-- per pane (end_pane_keys), the step keys (3.4: a toggle on release, the
-- level gesture and the held step's step editor, S.lib.pages_seq), the
-- gesture recorder keys, the key helpers and levels the pages share, and
-- the dispatch of key presses, releases and redraws to the layout records
-- in S.registry.grid_layouts (each lib/grid/layout_<size>.lua's
-- S.lib.grid_pane.arrange record), chosen by each grid's exact size. The
-- functions that were global stay global, defined here.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local GRID_HOLD = S.constants.GRID_HOLD
  local GRID_PORTS = S.constants.GRID_PORTS

  -- Grid devices (support multiple grids); SETUP counts S.MAX_GRID_PORTS
  S.MAX_GRID_PORTS = 4
  S.grids = {}

  -- Grid UI state (3.8, design §10.1). Each pane of each port shows its own
  -- page, side and half: S.grid_panes[port][pane] = {page, side, half}, set
  -- by set_page and set_half; a pane with no entry shows its layout's start
  -- page. Pages are numbered alike on every layout
  -- (S.constants.GRID_PAGES): 1 patterns, 2 faders, 3 scenes, 4 sources, 5
  -- positions, 6 voices, 7 fx
  local GRID_PAGES = S.constants.GRID_PAGES
  local MAX_GRID_PAGES = GRID_PAGES.count
  local MAX_HALVES = 2
  S.grid_panes = {}
  S.param_page = 1
  S.grid_voice_select = 1

  -- The faders' geometry: four faders a fader page, sixteen keys a fader
  -- (lib/grid/faders.lua aliases it)
  local GRID_LAYOUT = {fader_rows = 4, fader_width = 16}
  M.GRID_LAYOUT = GRID_LAYOUT

  local function whole_number_in(value, low, high)
    return type(value) == "number" and value >= low and value <= high and value % 1 == 0
  end

  -- 3.6: a port of a grid that is no norns device (S.constants.GRID_PORTS,
  -- above norns' 1..S.MAX_GRID_PORTS), attached by M.attach_virtual
  local function virtual_port(port)
    for _, each in pairs(GRID_PORTS) do
      if port == each then return true end
    end
    return false
  end

  -- Any port a grid can be on: norns' four or a virtual one
  local function grid_port_number(port)
    return whole_number_in(port, 1, S.MAX_GRID_PORTS) or virtual_port(port)
  end

  -- The entry of a port's pane, or nil (the pane shows its start)
  local function pane_entry(port, pane)
    local panes = S.grid_panes[port]
    return panes and panes[pane or 1]
  end

  -- The pane's start page: its layout's start_pages entry, patterns for a
  -- port with no layout and for a start page with no record yet
  local function start_page(port, pane)
    local layout = M.layout_of(port)
    local page = layout and layout.start_pages and layout.start_pages[pane or 1] or GRID_PAGES.patterns
    if S.registry.grid_pages[page] == nil then return GRID_PAGES.patterns end
    return page
  end

  -- The panes of the grid on the port (1 with no grid)
  local function pane_count(port)
    local layout = M.layout_of(port)
    return layout and layout.panes or 1
  end

  -- Pages per port and pane (pane defaults to 1): the page, side (1 or 2)
  -- and half (1 or 2, a 64's shown half) the pane shows
  function M.page(port, pane)
    local entry = pane_entry(port, pane)
    if entry then return entry.page end
    return start_page(port, pane)
  end

  function M.side(port, pane)
    local entry = pane_entry(port, pane)
    return entry and entry.side or 1
  end

  function M.half(port, pane)
    local entry = pane_entry(port, pane)
    return entry and entry.half or 1
  end

  -- What a pane shows, as "<pane>:<page>:<side>:<half>": a press record
  -- keeps it to know whether its pane still shows what it was pressed on
  function M.view(port, pane)
    pane = pane or 1
    return pane .. ":" .. M.page(port, pane) .. ":" .. M.side(port, pane) .. ":" .. M.half(port, pane)
  end

  -- A change of what a pane shows ends what the pane's keys were pressed
  -- to do (M.end_pane_keys, below)
  local function set_pane(port, pane, page, side, half)
    if page ~= M.page(port, pane) or side ~= M.side(port, pane) or half ~= M.half(port, pane) then
      M.end_pane_keys(port, pane)
    end
    S.grid_panes[port] = S.grid_panes[port] or {}
    S.grid_panes[port][pane] = {page = page, side = side, half = half}
  end

  -- Show a page on a pane (pane and side default to 1). Refused: a port
  -- that is no grid port, a page outside 1..GRID_PAGES.count, a pane the
  -- grid has not (1 with no grid), a side the page has not (1 for a page
  -- with no record). A page with no record is accepted and drawn dark. A
  -- change of page or side ends what the pane's keys were pressed to do;
  -- the other pane's keys and the strips' are left alone
  function M.set_page(port, page, pane, side)
    pane, side = pane or 1, side or 1
    if not grid_port_number(port) then return end
    if not whole_number_in(page, 1, MAX_GRID_PAGES) then return end
    if not whole_number_in(pane, 1, pane_count(port)) then return end
    local record = S.registry.grid_pages[page]
    if not whole_number_in(side, 1, record and record.sides or 1) then return end
    set_pane(port, pane, page, side, M.half(port, pane))
  end

  -- Show a half (1 or 2) of a pane: the 64's chooser. A change ends the
  -- pane's keys
  function M.set_half(port, pane, half)
    pane = pane or 1
    if not grid_port_number(port) then return end
    if not whole_number_in(pane, 1, pane_count(port)) or not whole_number_in(half, 1, MAX_HALVES) then return end
    set_pane(port, pane, M.page(port, pane), M.side(port, pane), half)
  end

  -- Whether any pane of any connected grid shows the page (and the side,
  -- when given): redraw only when one does
  function M.any_page(page, side)
    for port, grid_port in pairs(S.grids) do
      local layout = grid_port.device and M.layout_of(port)
      for pane = 1, layout and layout.panes or 0 do
        if M.page(port, pane) == page and (side == nil or M.side(port, pane) == side) then return true end
      end
    end
    return false
  end

  -- Held keys, per port: S.grid_held[port][x][y] = press time (util.time()),
  -- set on press and cleared on release, on the port's grid.remove and in
  -- cleanup. Private to this module, per port and key: the pending hold
  -- clocks (hold_clocks), the consumed keys (consumed_keys), the step keys
  -- the step-level gesture sees (step_keys: {voice, step, level_key, second,
  -- fired})
  -- and each port's layout state (port_states)
  S.grid_held = {}
  local hold_clocks = {}
  local consumed_keys = {}
  local step_keys = {}
  local port_states = {}
  -- The role a held key was pressed in, when it acts at its release (3.4:
  -- "gesture <k>", "mute <v>"; press_as, pressed_as): a release acts only
  -- for the key pressed in that role, never for one pressed on another page
  local key_roles = {}
  -- 3.9 (3a): the cell keys a lane's line takes (cell_key: {id, index,
  -- on_tap, on_value} for a held cell, {id, second = true} for a spent
  -- second key), and each held key's press token (a fresh table at every
  -- press, which M.still's answer compares), both per port and key
  local cell_keys = {}
  local press_tokens = {}

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

  -- A pending hold's clock runs through the clock helper (hold_clocks holds
  -- its handle) and is ended with S.lib.clocks.stop, which retires one
  -- whose wake may be posted (#870): its sleep returns false and fn never
  -- runs. Only cleanup's step cancels them outright
  local function stop_hold(port, x, y)
    local handle = key_value(hold_clocks, port, x, y)
    if handle == nil then return end
    set_key_value(hold_clocks, port, x, y, nil)
    S.lib.clocks.stop(handle)
  end

  -- Run fn once if the key (held now) is still held after `seconds`. Its
  -- release, the port's grid.remove and cleanup end it
  function M.on_hold(port, x, y, seconds, fn)
    if M.held(port, x, y) == nil then return end
    stop_hold(port, x, y)
    local handle = S.lib.clocks.run(function(hold)
      if not hold.sleep(seconds) then return end
      set_key_value(hold_clocks, port, x, y, nil)
      fn()
    end)
    set_key_value(hold_clocks, port, x, y, handle)
  end

  -- The held step key that opened 3.4's step editor (design §8.7), as
  -- {port, x, y}, or nil: its release, the end of its gesture (a page
  -- change, a half switch, the voice's pattern replaced), a press with no
  -- release before it and its grid's removal close the editor
  -- (S.lib.pages_seq.close_step_editor), so no editor outlives its key
  local step_editor = {key = nil}

  -- Whether the key at (x, y) on the port opened the step editor
  local function opened_step_editor(port, x, y)
    local key = step_editor.key
    return key ~= nil and key.port == port and key.x == x and key.y == y
  end

  -- Close the step editor if the key at (x, y) on the port opened it and
  -- it is still open for that port (S.lib.pages_seq.step_editor()), so a
  -- stale key never closes an editor opened elsewhere since
  local function close_step_editor_of(port, x, y)
    if not opened_step_editor(port, x, y) then return end
    step_editor.key = nil
    local open = S.lib.pages_seq.step_editor()
    if open and open.port == port then S.lib.pages_seq.close_step_editor(port) end
  end

  -- End the step gesture of the key at (x, y) on the port: its pending
  -- editor hold is stopped, an editor it opened closes, and it is no
  -- longer a step key (its release toggles nothing)
  local function drop_step_key(port, x, y)
    if key_value(step_keys, port, x, y) == nil then return end
    set_key_value(step_keys, port, x, y, nil)
    stop_hold(port, x, y)
    close_step_editor_of(port, x, y)
  end

  -- End every pending hold of a port with end_clock (S.lib.clocks.stop;
  -- cleanup's step passes cancel) and forget its keys' roles
  local function end_holds(port, end_clock)
    local columns = hold_clocks[port]
    hold_clocks[port] = nil
    key_roles[port] = nil
    for _, rows in pairs(columns or {}) do
      for _, handle in pairs(rows) do end_clock(handle) end
    end
  end

  -- End every pending hold of a port (stopped) and forget its keys' roles:
  -- forget_port. The keys stay held
  function M.end_port_holds(port)
    end_holds(port, S.lib.clocks.stop)
  end

  -- Note that the key at (x, y), held now, was pressed in role (a string:
  -- "gesture 2", "mute 3"), so its release acts in that role
  -- (pressed_as). A press, the release, a page change and the port's
  -- forget_port forget it
  function M.press_as(port, x, y, role)
    if M.held(port, x, y) == nil then return end
    set_key_value(key_roles, port, x, y, role)
  end

  -- Whether the key at (x, y) is held in role, pressed in it on the page
  -- the port shows: a release-acting key acts only then
  function M.pressed_as(port, x, y, role)
    return role ~= nil and key_value(key_roles, port, x, y) == role
  end

  -- End what the keys of one pane of a port were pressed to do (a page,
  -- side or half change, the 64's chooser opening): for each key the
  -- layout puts in that pane (pane_at), its step gesture ends (it toggles
  -- nothing at its release, takes no level and closes a step editor it
  -- opened), its pending hold is stopped and its role forgotten. The keys
  -- stay held; a strip key (pane_at nil) and the other pane's are never
  -- touched, so fill, a tempo repeat and NV go on
  function M.end_pane_keys(port, pane)
    local layout = M.layout_of(port)
    if layout == nil or layout.pane_at == nil then return end
    local function each_key(tables, fn)
      local keys = {}
      for x, rows in pairs(tables[port] or {}) do
        for y in pairs(rows) do
          if layout.pane_at(x, y) == pane then keys[#keys + 1] = {x, y} end
        end
      end
      for _, key in ipairs(keys) do fn(key[1], key[2]) end
    end
    each_key(step_keys, function(x, y) drop_step_key(port, x, y) end)
    each_key(hold_clocks, function(x, y) stop_hold(port, x, y) end)
    each_key(key_roles, function(x, y) set_key_value(key_roles, port, x, y, nil) end)
    each_key(cell_keys, function(x, y) set_key_value(cell_keys, port, x, y, nil) end)
    each_key(press_tokens, function(x, y) set_key_value(press_tokens, port, x, y, nil) end)
  end

  -- 3.9 (3a): a function of no argument, true while the press now down at
  -- (x, y) is still that same press on what its pane showed: false after
  -- its release, a page, side or half change of its pane (end_pane_keys,
  -- the 64's chooser opening among them), the port's forget (an unplug, a
  -- rotation) and for any later press of the key. A pattern's replacement
  -- leaves it. A key not held gives a function that is always false
  function M.still(port, x, y)
    local token = key_value(press_tokens, port, x, y)
    return function()
      return token ~= nil and key_value(press_tokens, port, x, y) == token
    end
  end

  -- Forget a port's keys: pending holds (stopped), held, consumed and step
  -- keys (a step editor one of them opened closes), their roles, its layout
  -- state and its panes. The port is left with no held keys' table, as a
  -- port never attached has none (a press makes it again)
  local function forget_port(port)
    local key = step_editor.key
    if key and key.port == port then close_step_editor_of(port, key.x, key.y) end
    M.end_port_holds(port)
    S.grid_held[port] = nil
    consumed_keys[port] = nil
    step_keys[port] = nil
    cell_keys[port] = nil
    press_tokens[port] = nil
    port_states[port] = nil
    S.grid_panes[port] = nil
  end

  local function press_key(port, x, y)
    -- a press with no release before it (a missed event) starts over
    drop_step_key(port, x, y)
    stop_hold(port, x, y)
    set_key_value(consumed_keys, port, x, y, nil)
    set_key_value(key_roles, port, x, y, nil)
    set_key_value(cell_keys, port, x, y, nil)
    set_key_value(S.grid_held, port, x, y, util.time())
    set_key_value(press_tokens, port, x, y, {})
  end

  local function release_key(port, x, y)
    drop_step_key(port, x, y)
    set_key_value(S.grid_held, port, x, y, nil)
    set_key_value(consumed_keys, port, x, y, nil)
    set_key_value(key_roles, port, x, y, nil)
    set_key_value(cell_keys, port, x, y, nil)
    set_key_value(press_tokens, port, x, y, nil)
  end

  -- A step key's release (3.4, design §8.7): the held step it pressed
  -- toggles, unless it was consumed (by the level gesture, or because it
  -- opened the step editor) or its gesture ended meanwhile; a level key
  -- toggles nothing. The core does it for every layout, whatever the
  -- layout does with the release
  local function release_step_key(port, x, y)
    local entry = key_value(step_keys, port, x, y)
    if entry == nil or entry.level_key or M.consumed(port, x, y) then return end
    toggle_pattern_step(entry.voice, entry.step)
  end

  -- A step's level from a key's position along the voice's shown steps
  function M.level_for_position(position, positions)
    local level = math.max(1, util.round(position * MAX_STEP_LEVEL / positions))
    return math.min(level, MAX_STEP_LEVEL)
  end

  -- The voice's held step on this port, other than (x, y): its entry and
  -- coordinates, or nil. A voice has at most one (#450): step_key records a
  -- key as a held step only while the voice has none, and every later key
  -- of the voice is a level key, which never counts
  local function held_step(port, voice_idx, x, y)
    for key_x, rows in pairs(step_keys[port] or {}) do
      for key_y, entry in pairs(rows) do
        if entry.voice == voice_idx and not entry.level_key and not (key_x == x and key_y == y)
          and M.held(port, key_x, key_y) ~= nil then
          return entry, key_x, key_y
        end
      end
    end
    return nil
  end

  -- A held step key, held GRID_HOLD.step_edit_seconds: open the step
  -- editor for its voice and step (SEQ's S.lib.pages_seq.open_step_editor,
  -- which pushes it as the screen's modal owner) and note the key as the
  -- one that opened it. The key is consumed, so its release toggles
  -- nothing; it closes the editor instead
  local function open_step_editor(port, x, y, voice_idx, step)
    if not S.lib.pages_seq.open_step_editor(voice_idx, step, port) then return end
    step_editor.key = {port = port, x = x, y = y}
    M.consume(port, x, y)
  end

  -- A pattern key (3.4, design §8.7). Pressed, the key becomes the voice's
  -- held step on this port and toggles nothing yet, unless the voice already
  -- has one: then that step gets this key's level (its position,
  -- 1..positions, along the voice's shown steps), both keys are consumed,
  -- the held step's pending editor hold is stopped and this key is a
  -- level key for as long as it is down (it never takes a level itself).
  -- A held step toggles at its release (release_step_key, unless consumed);
  -- held GRID_HOLD.step_edit_seconds (on_hold) it opens the step editor,
  -- and its release closes it. step_key's own z == 0 does nothing. A
  -- voice, step or position out of range does nothing, so only valid
  -- steps are ever recorded as held (and later take a level).
  -- 3.9 (3a): `second` is what the held step's second key does: "level"
  -- (nil, the default) the above; or a function, second(voice, held step,
  -- this key's step), called for every key of the voice pressed before
  -- the held step's hold fires (a third key calls it again), with both
  -- keys consumed and the hold stopped as for a level. The held key's own
  -- `second` decides. Once its hold has fired (the entry's `fired`, set
  -- whether or not the editor opened), a further key of the voice does
  -- nothing: it is consumed, calls nothing and holds nothing. Any other
  -- `second` does nothing
  function M.step_key(port, x, y, z, voice_idx, step, position, positions, second)
    if z ~= 1 then return end
    if not whole_number_in(voice_idx, 1, NUM_VOICES) or not whole_number_in(step, 1, PATTERN_LENGTH) then return end
    if not whole_number_in(positions, 1, PATTERN_LENGTH) or not whole_number_in(position, 1, positions) then return end
    second = second or "level"
    if second ~= "level" and type(second) ~= "function" then return end
    local held, held_x, held_y = held_step(port, voice_idx, x, y)
    if held then
      M.consume(port, x, y)
      M.consume(port, held_x, held_y)
      stop_hold(port, held_x, held_y)
      set_key_value(step_keys, port, x, y, {voice = voice_idx, step = step, level_key = true})
      if held.second == "level" then
        S.lib.sequencer.set_level(voice_idx, held.step, M.level_for_position(position, positions))
      elseif not held.fired then
        held.second(voice_idx, held.step, step)
      end
      return
    end
    local entry = {voice = voice_idx, step = step, second = second}
    set_key_value(step_keys, port, x, y, entry)
    M.on_hold(port, x, y, GRID_HOLD.step_edit_seconds, function()
      entry.fired = true
      open_step_editor(port, x, y, voice_idx, step)
    end)
  end

  -- 3.9 (3a): the port's held cell of line `id`, other than (x, y): its
  -- entry and coordinates, or nil. A line has at most one: cell_key
  -- records a key as a held cell only while its line has none
  local function held_cell_of(port, id, x, y)
    for key_x, rows in pairs(cell_keys[port] or {}) do
      for key_y, entry in pairs(rows) do
        if entry.id == id and not entry.second and not (key_x == x and key_y == y)
          and M.held(port, key_x, key_y) ~= nil then
          return entry, key_x, key_y
        end
      end
    end
    return nil
  end

  -- The line id and index of the held cell at (x, y), or nil (a key that
  -- is no cell, a spent second key, a cell its pane's change ended)
  function M.held_cell(port, x, y)
    local entry = key_value(cell_keys, port, x, y)
    if entry == nil or entry.second then return nil end
    return entry.id, entry.index
  end

  -- 3.9 (3a): a cell key of a lane's line, `id` (a string) naming the line.
  -- Pressed, the key becomes the line's held cell on this port, unless the
  -- line has one: then that cell's on_value(its index, this key's
  -- position, positions) is called, both keys are consumed and this key is
  -- a spent second key while it is down (a further key of the line, with
  -- the cell still held, sets the value again). A held cell's release, not
  -- consumed, calls its on_tap(index) (release_cell_key). No hold clock,
  -- no editor. A pane's change and the port's forget end a held cell (its
  -- release then calls nothing); a pattern's replacement leaves it.
  -- cell_key's own z == 0 does nothing; anything out of range does nothing
  function M.cell_key(port, x, y, z, id, index, position, positions, on_tap, on_value)
    if z ~= 1 or M.held(port, x, y) == nil then return end
    if type(id) ~= "string" or not whole_number_in(index, 1, PATTERN_LENGTH) then return end
    if not whole_number_in(positions, 1, PATTERN_LENGTH) or not whole_number_in(position, 1, positions) then return end
    if type(on_tap) ~= "function" or type(on_value) ~= "function" then return end
    local held, held_x, held_y = held_cell_of(port, id, x, y)
    if held then
      M.consume(port, x, y)
      M.consume(port, held_x, held_y)
      set_key_value(cell_keys, port, x, y, {id = id, second = true})
      held.on_value(held.index, position, positions)
      return
    end
    set_key_value(cell_keys, port, x, y, {id = id, index = index, on_tap = on_tap, on_value = on_value})
  end

  -- A cell key's release: a held cell, not consumed, is tapped
  local function release_cell_key(port, x, y)
    local entry = key_value(cell_keys, port, x, y)
    if entry == nil or entry.second or M.consumed(port, x, y) then return end
    entry.on_tap(entry.index)
  end

  -- End the step gesture on voice_idx's step keys, on every port:
  -- S.lib.sequencer.replace_pattern (every whole-pattern change: clear,
  -- randomize, a 256's paste, a scene recall, a chain link) calls it, so a
  -- step held from before never takes a level in the new pattern, never
  -- toggles at its release and closes a step editor it opened (its pending
  -- hold is stopped). The keys stay held; the next step key of the voice
  -- is a held step of its own. Ruling 71: a replacement the open step
  -- editor makes itself (S.lib.pages_seq.step_editor_replacing(): its
  -- euclid and clear rows, its randomize and undo) keeps the key that
  -- opened it, so the editor stays open and the key's release closes it;
  -- every other key of the voice ends as above
  function M.end_step_gestures(voice_idx)
    for port, columns in pairs(step_keys) do
      for key_x, rows in pairs(columns) do
        for key_y, entry in pairs(rows) do
          local editor_keeps = opened_step_editor(port, key_x, key_y)
            and S.lib.pages_seq.step_editor_replacing()
          if entry.voice == voice_idx and not editor_keeps then drop_step_key(port, key_x, key_y) end
        end
      end
    end
  end

  -- End the step gesture on every step key held on one port, whatever the
  -- voice and pane, so a step held never takes a level, never toggles at
  -- its release and closes a step editor it opened. The keys stay held. A
  -- port that is neither 1..S.MAX_GRID_PORTS nor a virtual one does nothing
  function M.end_port_step_gestures(port)
    if not grid_port_number(port) then return end
    for key_x, rows in pairs(step_keys[port] or {}) do
      for key_y in pairs(rows) do drop_step_key(port, key_x, key_y) end
    end
    step_keys[port] = nil
  end

  -- The key levels every layout shares (S.constants.GRID_LEVELS, #526): a
  -- voice's on/off key, a lock key and the play keys from the state they
  -- show; the page and pick keys' pairs are read from M.LEVELS
  local LEVELS = S.constants.GRID_LEVELS
  M.LEVELS = LEVELS

  -- 3.4's keys every layout with them shares: a running voice that is
  -- silenced (muted, or another voice soloed: S.lib.voice_mix.silenced)
  -- on its on/off key (design §8.14), and the gesture recorders' keys
  -- (design §7.2, §11: a press, a hold that clears, a level per state)
  local SHARED_KEYS = {
    voice_silenced = 6,
    gesture_clear_seconds = GRID_HOLD.action_hold_seconds,
    gesture_levels = {empty = 2, stopped = 5, playing = 10, overdubbing = 13, recording = 15},
  }

  -- 12 running, 6 running but silenced, 2 stopped
  function M.voice_level(voice_idx)
    if not whole_number_in(voice_idx, 1, NUM_VOICES) then return 0 end
    if not S.voices[voice_idx].active then return LEVELS.voice_stopped end
    return S.lib.voice_mix.silenced(voice_idx) and SHARED_KEYS.voice_silenced or LEVELS.voice_running
  end

  -- Gesture recorder k's key (3.4, design §7.2, ruling 73), acting at its
  -- release as the 64's play key and the 256's mute keys do: a release
  -- before SHARED_KEYS.gesture_clear_seconds is S.lib.gestures.press(k)
  -- (empty -> recording -> playing -> stopped -> playing); the hold
  -- (on_hold) clears the recorder and consumes the key, so its release
  -- does nothing and a clear never plays, records or ends another
  -- recorder's recording first. Layouts pass the key's release on. Only a
  -- key pressed as this recorder's key (press_as, "gesture <k>") acts at
  -- its release: never one pressed on another page (a step key held into
  -- the scenes page), nor one the core never saw pressed. A recorder
  -- outside 1..NUM_GESTURES does nothing
  function M.gesture_key(port, x, y, z, k)
    if not whole_number_in(k, 1, S.constants.NUM_GESTURES) then return end
    local role = "gesture " .. k
    if z == 1 then
      M.press_as(port, x, y, role)
      M.on_hold(port, x, y, SHARED_KEYS.gesture_clear_seconds, function()
        S.lib.gestures.clear(k)
        M.consume(port, x, y)
      end)
    elseif M.pressed_as(port, x, y, role) then
      S.lib.gestures.press(k)
    end
  end

  -- Its LED: empty 2, stopped 5, playing 10, overdubbing 13 (steady,
  -- never the waiting blink: an overdub records like a recording, #879),
  -- recording 15 (0 for no recorder). An overdub's start and end repaint
  -- through the recorder's own redraw
  function M.gesture_level(k)
    if not whole_number_in(k, 1, S.constants.NUM_GESTURES) then return 0 end
    local levels = SHARED_KEYS.gesture_levels
    if S.lib.gestures.overdubbing(k) then return levels.overdubbing end
    return levels[S.lib.gestures.state(k)] or 0
  end

  function M.lock_level(voice_idx)
    if not whole_number_in(voice_idx, 1, NUM_VOICES) then return 0 end
    return S.locked[voice_idx] and LEVELS.locked or LEVELS.unlocked
  end

  -- The waiting blink (#876, the one rule #593's bookmark keys began): a
  -- key whose quantized action waits alternates between LEVELS.waiting_high
  -- and waiting_low (15 and 2), each for LEVELS.waiting_ticks (4) of the
  -- playheads' 15 Hz ticks, which blink_tick counts. ticks: the ticks
  -- counted; shown: the signature of the waits the grids show at the last
  -- tick (nil while none waits)
  local blink = {ticks = 0, shown = nil}

  -- The blink's level at tick `now` (the ticks counted so far by default)
  function M.waiting_level(now)
    now = now or blink.ticks
    return math.floor(now / LEVELS.waiting_ticks) % LEVELS.waiting_phases == 0 and LEVELS.waiting_high
      or LEVELS.waiting_low
  end

  -- What the waits the grids show come to, with the blink's level; nil
  -- when none shows. One redraw rule for every blink (#593's): a wait
  -- counts only while a pane of a connected grid shows its key. The play
  -- key's start always counts: PL is on the 256's, 128h's and 128v's
  -- strip and NV on the 64's, and a strip shows whatever page its panes
  -- show. Each voice's freeze key counts while a pane shows the voices
  -- page, the scene keys' recall (its slot) while one shows the scenes
  -- page, the cell of a voice's jump or loop (S.lib.positions.waiting_cell)
  -- while one shows the positions page's cells. A bookmark key's wait is
  -- positions' (its display signature, under the same rule)
  local function blink_signature()
    local quantize = S.lib.quantize
    local parts = {}
    if S.lib.sequencer.play_state() == "armed" then parts[#parts + 1] = "play" end
    local scene = quantize.waiting_detail("scene")
    if scene ~= nil and M.any_page(GRID_PAGES.scenes) then parts[#parts + 1] = "scene " .. tostring(scene) end
    local cells_shown = M.any_page(GRID_PAGES.positions, 1)
    local freeze_shown = M.any_page(GRID_PAGES.voices)
    for voice_idx = 1, NUM_VOICES do
      if freeze_shown and S.lib.freeze.waiting(voice_idx) then parts[#parts + 1] = "freeze " .. voice_idx end
      local cell = cells_shown and S.lib.positions.waiting_cell(voice_idx)
      if cell then parts[#parts + 1] = "cell " .. voice_idx .. ":" .. cell end
    end
    if #parts == 0 then return nil end
    parts[#parts + 1] = M.waiting_level()
    return table.concat(parts, ",")
  end

  -- The playheads' tick (lib/playheads.lua): counts a tick and repaints
  -- the grids when what the waiting keys show changed (a phase of the
  -- blink, a wait begun, ended or moved, wherever it was started or taken
  -- back), once more when the last one ends; while none shows it repaints
  -- nothing. No param action repaints for a wait
  function M.blink_tick()
    blink.ticks = blink.ticks + 1
    local signature = blink_signature()
    if signature ~= blink.shown then grid_redraw() end
    blink.shown = signature
  end

  -- The play key (PL, and NV while the 64's chooser is not shown): playing,
  -- stopped, or blinking while a start waits (S.lib.sequencer.play_state)
  function M.play_level()
    local state = S.lib.sequencer.play_state()
    if state == "armed" then return M.waiting_level() end
    return state == "playing" and LEVELS.playing or LEVELS.stopped
  end

  -- The scene keys' levels, one rule for every layout with a scenes page
  -- (#452): a recall key 8 for a saved scene, 2 for an empty slot, 10 for
  -- the slot the running sequencer recalls next (#303), 15 for the current
  -- scene, which wins (S.lib.scenes.shows_current: the scene a fade goes to
  -- blinks, #254); a fade key 6 saved, 2 empty. Both keys of the scene a
  -- quantized recall waits for (its slot, the action's detail) blink
  -- before all of these (#876). A slot outside 1..NUM_SCENES is 0
  local SCENE_LEVELS = {saved = 8, empty = 2, next = 10, current = 15, fade_saved = 6}

  local function scene_waits(slot) return S.lib.quantize.waiting_detail("scene") == slot end

  function M.scene_recall_level(slot)
    if not whole_number_in(slot, 1, S.constants.NUM_SCENES) then return 0 end
    if scene_waits(slot) then return M.waiting_level() end
    if S.lib.scenes.shows_current(slot) then return SCENE_LEVELS.current end
    if slot == S.lib.scenes.sequencer_next_slot() then return SCENE_LEVELS.next end
    return S.scenes[slot].populated and SCENE_LEVELS.saved or SCENE_LEVELS.empty
  end

  function M.scene_fade_level(slot)
    if not whole_number_in(slot, 1, S.constants.NUM_SCENES) then return 0 end
    if scene_waits(slot) then return M.waiting_level() end
    return S.scenes[slot].populated and SCENE_LEVELS.fade_saved or SCENE_LEVELS.empty
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

  -- The layout record of the grid connected to a port (S.lib.grid_pane's
  -- arrange record, {key, redraw, panes, pane_at, start_pages}:
  -- docs/notes/lua/grid/pane.md), or nil (no grid, or a size with no
  -- layout)
  function M.layout_of(port)
    local grid_port = S.grids[port]
    return grid_port and S.registry.grid_layouts[grid_layout(grid_port)] or nil
  end

  -- Whether a pane of a connected grid shows the FX page: the FX params'
  -- actions redraw the grids only then
  function M.any_fx_faders()
    return M.any_page(GRID_PAGES.fx)
  end

  -- Per attached port, the device its vport held when attached (reconcile_ports)
  local attached_devices = {}

  -- The rotation setting per port (#323, a SETUP setting, never a param):
  -- norns' Grid:rotation, 0-3 (0, 90, 180 and 270 degrees; 1 or 3 stands a
  -- 128 upright as the 8x16), kept in grids.data in the data folder and read
  -- at the grids' start step (settings[port], nil reads as 0). sizes[port]
  -- is the size ("16x8") an attached port's grid reported when it was last
  -- attached or turned: one that reports another, turned outside Strata,
  -- starts over (follow_size)
  local GRID_ROTATION = {file = "grids.data", version = 1, last = 3, settings = {}, sizes = {}, backup_suffix = ".bak"}

  local function rotation_path() return _path.data .. "strata/" .. GRID_ROTATION.file end

  local function size_of(grid_port) return grid_port.cols .. "x" .. grid_port.rows end

  M.MAX_ROTATION = GRID_ROTATION.last

  -- The port's rotation setting, 0-3
  function M.rotation(port)
    return GRID_ROTATION.settings[port] or 0
  end

  -- Read grids.data (parsed, never run: S.lib.data_files.read): each port's
  -- whole number 0-3 is its setting; anything else (no file, one that does
  -- not parse, another version, a bad entry) reads as 0. A file that fails
  -- whole (it does not parse, another version, no rotation table) is set
  -- aside (grids.data.bak, ...) with one line, as io.data is; one that
  -- cannot be set aside stays, and the next set_rotation writes over it
  local function read_rotations()
    local settings = {}
    local path = rotation_path()
    local value, problem, why = S.lib.data_files.read(path)
    if type(value) == "table" and value.version == GRID_ROTATION.version and type(value.rotation) == "table" then
      for port = 1, S.MAX_GRID_PORTS do
        if whole_number_in(value.rotation[port], 0, GRID_ROTATION.last) then settings[port] = value.rotation[port] end
      end
    elseif value ~= nil or problem == "unreadable" then
      local backup, failure = S.lib.data_files.set_aside(path, GRID_ROTATION.backup_suffix)
      print("strata: " .. GRID_ROTATION.file .. " not used (" .. tostring(why or "not grid settings")
        .. "): every grid rotation is 0; "
        .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure))))
    end
    GRID_ROTATION.settings = settings
  end

  -- Turn the port's grid to its setting (norns reads its rows and cols again
  -- and updates the vport) and note the size it reports
  local function apply_rotation(port, grid_port)
    grid_port:rotation(M.rotation(port))
    GRID_ROTATION.sizes[port] = size_of(grid_port)
  end

  -- Store a grid port's vport, route its key events to grid_key and turn the
  -- grid to the port's rotation. Handlers live on the vport only: norns
  -- fires both device.key and vports[port].key, so also setting them on the
  -- device would run grid_key twice per press.
  -- norns' own grid module: the one its startup loaded (grid = require
  -- 'core/grid'), whatever a mod put in the global grid since. The midigrid
  -- mod's facade there has its own connect, which ignores the port, and no
  -- __newindex, so a handler assigned to it is never called by norns'
  -- hot-plug (#700). The global where norns' module is not found (the test
  -- stubs)
  local function norns_grid()
    local loaded = package.loaded["core/grid"]
    if type(loaded) == "table" and type(loaded.vports) == "table" then return loaded end
    return grid
  end

  -- Ports 1..S.MAX_GRID_PORTS take norns' own vports only (3.6, #700): the
  -- vport is read from norns' module, never through a grid.connect(port),
  -- so a mod's connect (midigrid's) never runs for them and its grid
  -- attaches as a virtual one. nil for a port norns has no vport for
  local function norns_vport(port)
    return norns_grid().vports[port]
  end

  local function attach_grid(port)
    local grid_port = norns_vport(port)
    if grid_port == nil then return nil end
    S.grids[port] = grid_port
    attached_devices[port] = grid_port.device
    grid_port.key = function(x, y, z)
      grid_key(port, x, y, z)
    end
    apply_rotation(port, grid_port)
    return grid_port
  end

  -- A port whose grid reports another size than when it was attached or
  -- turned (a rotation made outside Strata: no add, no remove) starts over,
  -- as a grid plugged in does. Run before a key and a redraw reach it
  local function follow_size(port, grid_port)
    local size = size_of(grid_port)
    if GRID_ROTATION.sizes[port] == size then return end
    forget_port(port)
    GRID_ROTATION.sizes[port] = size
  end

  -- Set the port's rotation (a whole number 0-3): written to grids.data
  -- first, so a write that fails sets nothing (false); then a grid on the
  -- port is turned and the port starts over, as a grid plugged in does (its
  -- page, held keys, holds and layout state forgotten), and the grids and
  -- the screen redraw. false for a port or rotation out of range
  function M.set_rotation(port, rotation)
    if not whole_number_in(port, 1, S.MAX_GRID_PORTS) or not whole_number_in(rotation, 0, GRID_ROTATION.last) then
      return false
    end
    if rotation == M.rotation(port) then return true end
    local settings = {}
    for each_port = 1, S.MAX_GRID_PORTS do settings[each_port] = M.rotation(each_port) end
    settings[port] = rotation
    util.make_dir(_path.data .. "strata/")
    local written, problem = S.lib.data_files.write(rotation_path(), {version = GRID_ROTATION.version, rotation = settings})
    if not written then
      print("strata: " .. GRID_ROTATION.file .. " not saved: " .. tostring(problem))
      return false
    end
    GRID_ROTATION.settings = settings
    local grid_port = S.grids[port]
    if grid_port and grid_port.device then
      forget_port(port)
      apply_rotation(port, grid_port)
    end
    grid_redraw()
    request_redraw()
    return true
  end

  function grid_init()
    read_rotations()
    -- Connect up to 4 grids
    for port = 1, S.MAX_GRID_PORTS do
      local vport = norns_vport(port)
      if vport and vport.device then
        local grid_port = attach_grid(port)
        print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
      end
    end
    grid_redraw()
  end

  -- A port's grid goes (unplugged, its vport emptied in SYSTEM > DEVICES,
  -- a virtual grid detached; #932): the attached grid's key handler is
  -- cleared and its entry, its recorded device and its size go, then the
  -- port is forgotten (forget_port: its pending holds never fire, no scene
  -- save from a removed grid), so it keeps no held keys' table
  local function detach(port)
    local grid_port = S.grids[port]
    if grid_port then grid_port.key = nil end
    S.grids[port] = nil
    attached_devices[port] = nil
    GRID_ROTATION.sizes[port] = nil
    forget_port(port)
  end

  -- Hot-plug. norns passes the raw device here; store its port's vport (as
  -- grid_init does) rather than the device, which has no .device field.
  -- A grid plugged in starts with no held keys, on its start pages. Both handlers
  -- go on norns' own module (norns_grid), which its hot-plug calls
  local function grid_added(device)
    local port = device.port
    if not port or norns_vport(port) == nil then return end  -- device not assigned to a grid port
    forget_port(port)
    local grid_port = attach_grid(port)
    print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
    grid_redraw()
    request_redraw()  -- SETUP lists the connected grids
  end

  local function grid_removed(device)
    local port = device.port
    if not port then return end
    detach(port)
    request_redraw()
    print("grid " .. port .. " disconnected")
  end

  norns_grid().add, norns_grid().remove = grid_added, grid_removed

  -- SYSTEM > DEVICES moves a grid to another port through norns'
  -- update_devices() alone (lua/core/menu/devices.lua): no grid.add, no
  -- grid.remove. Run as the norns menu closes: a vport holding a device that
  -- is not attached, or another device than the one attached, is forgotten
  -- and attached, as grid.add does; an attached port whose vport is empty is
  -- detached and forgotten, as grid.remove does. A port norns has no vport
  -- for (norns_vport) is left as it is; a virtual grid's port is never
  -- looked at
  function M.reconcile_ports()
    for port = 1, S.MAX_GRID_PORTS do
      local grid_port = norns_vport(port)
      local attached = S.grids[port]
      if grid_port == nil then
        -- not norns' vport: nothing to follow here
      elseif grid_port.device and (attached == nil or attached_devices[port] ~= grid_port.device) then
        forget_port(port)
        attach_grid(port)
        print("grid " .. port .. " connected: " .. grid_port.cols .. "x" .. grid_port.rows)
      elseif attached and grid_port.device == nil then
        detach(port)
        print("grid " .. port .. " disconnected")
      end
    end
    grid_redraw()
    request_redraw()  -- SETUP lists the connected grids
  end

  S.register_menu_close(function() M.reconcile_ports() end)

  -- 3.6 (design §0.1, §9): a grid that is no norns device (a remote grid,
  -- the midigrid mod's) on a virtual port, one of S.constants.GRID_PORTS'
  -- values. device is a table with whole-number cols and rows (at least
  -- 1), a truthy device field and the functions led, all, refresh and
  -- rotation, called as methods; its key is set to reach grid_key(port, ...).
  -- The port's old state (and an old device's handler) is forgotten, and
  -- the grids redraw. true when attached; false for any other port or device
  local function virtual_device(device)
    if type(device) ~= "table" or not device.device then return false end
    if not whole_number_in(device.cols, 1, math.huge) or not whole_number_in(device.rows, 1, math.huge) then
      return false
    end
    for _, method in ipairs({"led", "all", "refresh", "rotation"}) do
      if type(device[method]) ~= "function" then return false end
    end
    return true
  end

  function M.attach_virtual(port, device)
    if not virtual_port(port) or not virtual_device(device) then return false end
    local old = S.grids[port]
    if old and old ~= device then old.key = nil end
    forget_port(port)
    S.grids[port] = device
    attached_devices[port] = device.device
    GRID_ROTATION.sizes[port] = size_of(device)
    device.key = function(x, y, z)
      grid_key(port, x, y, z)
    end
    grid_redraw()
    return true
  end

  -- A virtual port's grid goes (detach): its held keys and holds are
  -- forgotten, its key handler cleared, its entry removed. Any other port
  -- does nothing
  function M.detach_virtual(port)
    if not virtual_port(port) then return end
    detach(port)
  end

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
      stop_hold(port, x, y)
      if layout and not M.consumed(port, x, y) then layout.key(port, x, y, 0) end
      release_step_key(port, x, y)
      release_cell_key(port, x, y)
    end
  end

  -- Presses and releases. A press is held (S.grid_held) before the layout
  -- sees it. A release stops the key's hold, reaches the layout unless the
  -- key was consumed, toggles a held step key's step (release_step_key),
  -- taps a held cell (release_cell_key, 3.9's 3a), then forgets the key
  -- (release_key), also when the layout, the toggle or the tap raised
  -- (#620), so no key stays held. Layouts get key(port, x, y, z)
  -- and return on z == 0 unless they handle releases. One repaint per key,
  -- also when the handler fails (its error, the first one, is raised once,
  -- after the repaint)
  function grid_key(port, x, y, z)
    local grid_port = S.grids[port]
    if not grid_port then return end
    follow_size(port, grid_port)
    if x < 1 or x > grid_port.cols or y < 1 or y > grid_port.rows then return end

    key_repaint.handling = true
    local handled, key_error = xpcall(handle_key, debug.traceback, port, grid_port, x, y, z)
    if z ~= 1 then
      local released, release_error = xpcall(release_key, debug.traceback, port, x, y)
      if handled and not released then handled, key_error = false, release_error end
    end
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

  -- Per port: the key (`message`) of its layout's redraw error last printed
  -- (per port, so another grid of the same layout drawing well never clears
  -- it and the error prints once)
  local redraw_errors = {}

  -- Each grid is cleared, drawn by its layout and refreshed. A layout's
  -- redraw runs contained (the frame's contained_call, #441): its error is
  -- printed once per distinct message, the grid is still refreshed, the
  -- grids after it are drawn, and whoever asked for the redraw (a key, a
  -- voice toggle, the pattern clock, a poll) goes on
  function grid_redraw()
    if next(S.grids) == nil then return end  -- no grids: nothing to do
    if key_repaint.handling then return end  -- grid_key paints once the key is handled

    for port, grid_port in pairs(S.grids) do
      if grid_port.device then
        follow_size(port, grid_port)
        local layout = S.registry.grid_layouts[grid_layout(grid_port)]

        grid_port:all(0)

        if layout then
          S.lib.ui_frame.contained_call(redraw_errors, port, "grid redraw", layout.redraw, port, grid_port)
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
  -- the held keys, clear every vport's key handler, put its grid back to
  -- rotation 0 (norns' grid.cleanup() keeps a rotation, so the next script
  -- would find a turned 128 as an 8x16; the port's setting stays in
  -- grids.data) and leave it dark, and hand hot-plug back (no-ops, on norns'
  -- own module, #700; norns' grid.cleanup() restores its own at a script
  -- change). norns' SLEEP runs only cleanup() before the system shuts down,
  -- so a key or a grid plugged meanwhile reaches nothing (#468)
  S.register_cleanup(S.constants.CLEANUP_ORDER.grids_dark, function()
    for port = 1, S.MAX_GRID_PORTS do
      end_holds(port, S.lib.clocks.cancel)
      forget_port(port)
    end
    for _, port in pairs(GRID_PORTS) do
      end_holds(port, S.lib.clocks.cancel)
      forget_port(port)
    end
    for _, grid_port in pairs(S.grids) do
      grid_port.key = nil
      grid_port:rotation(0)
      grid_port:all(0)
      grid_port:refresh()
    end
    norns_grid().add = function() end
    norns_grid().remove = function() end
  end)

  -- Only a held key is a step key, is consumed, waits for a hold, has a
  -- role, is a cell key or has a press token (3.9, 3a); the step editor's
  -- key and an open editor agree; a port has an attached device recorded
  -- exactly while it is attached (norns' ports and the virtual ones), and
  -- no grid is on any other port
  S.register_invariant("grid keys", function()
    for port in pairs(S.grids) do
      if not grid_port_number(port) then return "a grid is attached on port " .. tostring(port) end
    end
    local ports = {}
    for port = 1, S.MAX_GRID_PORTS do ports[#ports + 1] = port end
    for _, port in pairs(GRID_PORTS) do ports[#ports + 1] = port end
    for _, port in ipairs(ports) do
      if (S.grids[port] ~= nil) ~= (attached_devices[port] ~= nil) then
        return "grid " .. port .. (S.grids[port] and " is attached with no device recorded"
          or " is not attached but has a device recorded")
      end
    end
    -- 3.9 (#930): the step editor's key is a held step it consumed, and an
    -- open editor has its key on the editor's port (the grid is its one
    -- opener while the script runs)
    local key = step_editor.key
    if key then
      local what = "the step editor's key, grid " .. key.port .. " key " .. key.x .. "," .. key.y .. ", is "
      local entry = key_value(step_keys, key.port, key.x, key.y)
      if M.held(key.port, key.x, key.y) == nil then return what .. "not held" end
      if not M.consumed(key.port, key.x, key.y) then return what .. "not consumed" end
      if entry == nil or entry.level_key then return what .. "no held step" end
    end
    local editor = S.lib.pages_seq and S.lib.pages_seq.step_editor()
    if editor and not (key and key.port == editor.port) then
      return "the step editor is open for port " .. tostring(editor.port) .. " with no held, consumed step key of that port"
    end
    for _, tables_of in ipairs({{"a step key", step_keys}, {"consumed", consumed_keys}, {"hold pending", hold_clocks},
        {"held in a role", key_roles}, {"a cell key", cell_keys}, {"pressed (a still's token)", press_tokens}}) do
      local kind, tables = tables_of[1], tables_of[2]
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

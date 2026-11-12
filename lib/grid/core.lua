-- lib/grid/core.lua
-- The grids Strata drives (S.grids, one vport per port) and what every
-- layout shares: the grid UI state (each port's page, S.param_page,
-- S.grid_voice_select), the 256's GRID_LAYOUT geometry
-- (S.lib.grid_core.GRID_LAYOUT), attaching vports, hot-plug, voice
-- selection, each port's held keys and holds (S.grid_held), the step keys
-- (3.4: a toggle on release, the level gesture and the held step's step
-- editor, S.lib.pages_seq), the scene-save and gesture recorder keys, the
-- key helpers and levels the layouts share, and the
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

  -- Grid UI state. Each port shows its own page (M.page), numbered alike on
  -- every layout (S.constants.GRID_PAGES): 1 patterns, 2 faders, 3 scenes,
  -- 4 sources and buffers (the 256 adds the FX faders), 5 positions
  local MAX_GRID_PAGES = S.constants.GRID_PAGES.count
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

  -- A page change ends what every key held on the port was pressed to do,
  -- so no key acts on a page it was not pressed on: its step gestures end
  -- (a step held on the page it leaves toggles nothing at its release,
  -- takes no level and closes a step editor it opened), its pending holds
  -- are canceled (a scene save, a pattern clear, a recorder's clear, a
  -- solo) and its keys' roles are forgotten (a recorder or mute key's
  -- release does nothing). Another port's keys are left alone
  function M.set_page(port, page)
    if not whole_number_in(port, 1, S.MAX_GRID_PORTS) then return end
    if not whole_number_in(page, 1, MAX_GRID_PAGES) then return end
    if page ~= M.page(port) then
      M.end_port_step_gestures(port)
      M.end_port_holds(port)
    end
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
  -- the step-level gesture sees (step_keys: {voice, step, level_key})
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
  -- editor hold is canceled, an editor it opened closes, and it is no
  -- longer a step key (its release toggles nothing)
  local function drop_step_key(port, x, y)
    if key_value(step_keys, port, x, y) == nil then return end
    set_key_value(step_keys, port, x, y, nil)
    cancel_hold(port, x, y)
    close_step_editor_of(port, x, y)
  end

  -- Cancel every pending hold of a port and forget its keys' roles: a page
  -- change (set_page) and forget_port. The keys stay held
  function M.end_port_holds(port)
    for _, rows in pairs(hold_clocks[port] or {}) do
      for _, clock_id in pairs(rows) do clock.cancel(clock_id) end
    end
    hold_clocks[port] = nil
    key_roles[port] = nil
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

  -- Forget a port's keys: pending holds (canceled), held, consumed and step
  -- keys (a step editor one of them opened closes), their roles, its layout
  -- state and its page
  local function forget_port(port)
    local key = step_editor.key
    if key and key.port == port then close_step_editor_of(port, key.x, key.y) end
    M.end_port_holds(port)
    S.grid_held[port] = {}
    consumed_keys[port] = nil
    step_keys[port] = nil
    port_states[port] = nil
    S.grid_pages[port] = nil
  end

  local function press_key(port, x, y)
    -- a press with no release before it (a missed event) starts over
    drop_step_key(port, x, y)
    cancel_hold(port, x, y)
    set_key_value(consumed_keys, port, x, y, nil)
    set_key_value(key_roles, port, x, y, nil)
    set_key_value(S.grid_held, port, x, y, util.time())
  end

  local function release_key(port, x, y)
    drop_step_key(port, x, y)
    set_key_value(S.grid_held, port, x, y, nil)
    set_key_value(consumed_keys, port, x, y, nil)
    set_key_value(key_roles, port, x, y, nil)
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
  -- the held step's pending editor hold is canceled and this key is a
  -- level key for as long as it is down (it never takes a level itself).
  -- A held step toggles at its release (release_step_key, unless consumed);
  -- held GRID_HOLD.step_edit_seconds (on_hold) it opens the step editor,
  -- and its release closes it. step_key's own z == 0 does nothing. A
  -- voice, step or position out of range does nothing, so only valid
  -- steps are ever recorded as held (and later take a level)
  function M.step_key(port, x, y, z, voice_idx, step, position, positions)
    if z ~= 1 then return end
    if not whole_number_in(voice_idx, 1, NUM_VOICES) or not whole_number_in(step, 1, PATTERN_LENGTH) then return end
    if not whole_number_in(positions, 1, PATTERN_LENGTH) or not whole_number_in(position, 1, positions) then return end
    local held, held_x, held_y = held_step(port, voice_idx, x, y)
    if held then
      S.patterns[voice_idx][held.step] = M.level_for_position(position, positions)
      S.lib.mutation.note_pattern_edit(voice_idx)
      M.consume(port, x, y)
      M.consume(port, held_x, held_y)
      cancel_hold(port, held_x, held_y)
      set_key_value(step_keys, port, x, y, {voice = voice_idx, step = step, level_key = true})
      return
    end
    set_key_value(step_keys, port, x, y, {voice = voice_idx, step = step})
    M.on_hold(port, x, y, GRID_HOLD.step_edit_seconds, function()
      open_step_editor(port, x, y, voice_idx, step)
    end)
  end

  -- End the step gesture on voice_idx's step keys, on every port:
  -- S.lib.sequencer.replace_pattern (every whole-pattern change: clear,
  -- randomize, a 256's paste, a scene recall, a chain link) calls it, so a
  -- step held from before never takes a level in the new pattern, never
  -- toggles at its release and closes a step editor it opened (its pending
  -- hold is canceled). The keys stay held; the next step key of the voice
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
  -- voice: a page change and a 64's half switch call it, so a step held on
  -- the page or half no longer shown never takes a level, never toggles at
  -- its release and closes a step editor it opened. The keys stay held. A
  -- port that is not a whole number in 1..S.MAX_GRID_PORTS does nothing
  function M.end_port_step_gestures(port)
    if not whole_number_in(port, 1, S.MAX_GRID_PORTS) then return end
    for key_x, rows in pairs(step_keys[port] or {}) do
      for key_y in pairs(rows) do drop_step_key(port, key_x, key_y) end
    end
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
    gesture_clear_seconds = GRID_HOLD.scene_save_seconds,
    gesture_levels = {empty = 2, stopped = 5, playing = 10, recording = 15},
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

  -- Its LED: empty 2, stopped 5, playing 10, recording 15 (0 for no recorder)
  function M.gesture_level(k)
    if not whole_number_in(k, 1, S.constants.NUM_GESTURES) then return 0 end
    return SHARED_KEYS.gesture_levels[S.lib.gestures.state(k)] or 0
  end

  function M.lock_level(voice_idx)
    if not whole_number_in(voice_idx, 1, NUM_VOICES) then return 0 end
    return S.frozen[voice_idx] and LEVELS.locked or LEVELS.unlocked
  end

  function M.play_level()
    return S.pattern_playing and LEVELS.playing or LEVELS.stopped
  end

  -- The scene keys' levels, one rule for every layout with a scenes page
  -- (#452): a recall key 8 for a saved scene, 2 for an empty slot, 10 for
  -- the slot the running sequencer recalls next (#303), 15 for the current
  -- scene, which wins (S.lib.scenes.shows_current: the scene a fade goes to
  -- blinks, #254); a fade key 6 saved, 2 empty; a save key 15 while its
  -- hold is pending, 4 otherwise. A slot outside 1..NUM_SCENES is 0
  local SCENE_LEVELS = {saved = 8, empty = 2, next = 10, current = 15, fade_saved = 6,
    save_pending = 15, save_idle = 4}

  function M.scene_recall_level(slot)
    if not whole_number_in(slot, 1, S.constants.NUM_SCENES) then return 0 end
    if S.lib.scenes.shows_current(slot) then return SCENE_LEVELS.current end
    if slot == S.lib.scenes.sequencer_next_slot() then return SCENE_LEVELS.next end
    return S.scenes[slot].populated and SCENE_LEVELS.saved or SCENE_LEVELS.empty
  end

  function M.scene_fade_level(slot)
    if not whole_number_in(slot, 1, S.constants.NUM_SCENES) then return 0 end
    return S.scenes[slot].populated and SCENE_LEVELS.fade_saved or SCENE_LEVELS.empty
  end

  -- The save key at (x, y) on the port
  function M.scene_save_level(port, x, y)
    return M.hold_pending(port, x, y) and SCENE_LEVELS.save_pending or SCENE_LEVELS.save_idle
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

  -- Whether a connected grid shows the macro faders or the morph now (3.4):
  -- its layout record's shows_modulation(port) says so (the 256's pages 1
  -- and 3, the 16x8's and 8x16's faders page on a bank and their scenes
  -- page; the 64 has none). The drift tick follows them only then
  -- (S.lib.grid_faders.follow_faders)
  function M.any_modulation_shown()
    for port, grid_port in pairs(S.grids) do
      local layout = grid_port.device and S.registry.grid_layouts[grid_layout(grid_port)]
      if layout and layout.shows_modulation and layout.shows_modulation(port) then return true end
    end
    return false
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
  local GRID_ROTATION = {file = "grids.data", version = 1, last = 3, settings = {}, sizes = {}}

  local function rotation_path() return _path.data .. "strata/" .. GRID_ROTATION.file end

  local function size_of(grid_port) return grid_port.cols .. "x" .. grid_port.rows end

  M.MAX_ROTATION = GRID_ROTATION.last

  -- The port's rotation setting, 0-3
  function M.rotation(port)
    return GRID_ROTATION.settings[port] or 0
  end

  -- Read grids.data (parsed, never run: S.lib.data_files.read): each port's
  -- whole number 0-3 is its setting; anything else (no file, one that does
  -- not parse, another version, a bad entry) reads as 0
  local function read_rotations()
    local settings = {}
    local value, problem, why = S.lib.data_files.read(rotation_path())
    if type(value) == "table" and value.version == GRID_ROTATION.version and type(value.rotation) == "table" then
      for port = 1, S.MAX_GRID_PORTS do
        if whole_number_in(value.rotation[port], 0, GRID_ROTATION.last) then settings[port] = value.rotation[port] end
      end
    elseif value ~= nil or problem == "unreadable" then
      print("strata: " .. GRID_ROTATION.file .. " not used (" .. tostring(why or "not grid settings")
        .. "): every grid rotation is 0")
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
  local function attach_grid(port)
    local grid_port = grid.connect(port)
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
    GRID_ROTATION.sizes[port] = nil
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
        GRID_ROTATION.sizes[port] = nil
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
      release_step_key(port, x, y)
    end
  end

  -- Presses and releases. A press is held (S.grid_held) before the layout
  -- sees it. A release cancels the key's hold, reaches the layout unless the
  -- key was consumed, toggles a held step key's step (release_step_key),
  -- then forgets the key (release_key), also when the layout or the toggle
  -- raised (#620), so no key stays held. Layouts get key(port, x, y, z)
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
  -- grids.data) and leave it dark, and hand hot-plug back (no-ops; norns'
  -- grid.cleanup() restores its own at a script change). norns' SLEEP runs
  -- only cleanup() before the system shuts down, so a key or a grid plugged
  -- meanwhile reaches nothing (#468)
  S.register_cleanup(S.constants.CLEANUP_ORDER.grids_dark, function()
    for port = 1, S.MAX_GRID_PORTS do forget_port(port) end
    for _, grid_port in pairs(S.grids) do
      grid_port.key = nil
      grid_port:rotation(0)
      grid_port:all(0)
      grid_port:refresh()
    end
    grid.add = function() end
    grid.remove = function() end
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
    for kind, tables in pairs({consumed = consumed_keys, ["hold pending"] = hold_clocks, ["held in a role"] = key_roles}) do
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

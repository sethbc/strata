-- lib/grid/layout_256.lua
-- The 16x16 grid: its five pages (1 patterns, 2 parameters, 3 scenes,
-- 4 buffers / FX, 5 positions), keys and LEDs. Registers
-- S.registry.grid_layouts["256"].
-- Rows 8 and 16 work on every page. Row 15 (pages 1 and 2) clears or
-- randomizes a pattern once held. Row 16 columns 9-15 copy and paste
-- patterns through a clipboard kept per port
-- (grid_core.port_state(port).clipboard). Freeze (S.lib.freeze): page 4's
-- column 12 on each voice's source row, and row 16 columns 1-7 while column
-- 8 of row 16 is held. The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local SOURCE_OPTIONS = S.constants.SOURCE_OPTIONS
  local grid_core = S.lib.grid_core
  local GRID_LAYOUT = grid_core.GRID_LAYOUT

  -- Keys and levels: row 8's tempo keys (column -> tempo change), row 16's
  -- copy/paste keys (columns 9-15 voices 1-7, column 16 clears the
  -- clipboard) and the scene page's next scene (the one the running
  -- sequencer recalls next)
  local LAYOUT_256 = {
    tempo_steps = {[5] = -10, [6] = -1, [7] = 1, [8] = 10},
    tempo_held_level = 15,
    tempo_level = 4,
    copy_first_column = 9,
    clear_column = 16,
    copied_level = 15,      -- the copied voice's key
    paste_level = 4,        -- the other voices' keys and column 16 while a pattern is copied
    empty_level = 2,        -- columns 9-16 with nothing copied
    sequencer_next_level = 10,
    freeze_column = 12,     -- page 4: voice v's freeze key on its source row (8 + v)
    freeze_hold_column = 8, -- row 16: held, columns 1-7 freeze instead of lock
    frozen_level = 15,
    unfrozen_level = 3,
    freeze_hold_level = 15, -- column 8 of row 16 while held
    freeze_key_level = 4,   -- and while not
    positions_page = 5,     -- row 8 column 12 shows it (15 lit on it, 4 otherwise)
    positions_key_column = 12,
    positions_key_level = 4,
    strip_first_row = 9,    -- page 5: voice v's bookmark strip is on row 8 + v
    strip_key_columns = {[1] = 1, [2] = 2, [3] = 3, [4] = 4, [6] = "store", [7] = "hold", [8] = "whole"},
    -- row 15 (pages 1 and 2): columns 1-7 clear voices 1-7's patterns,
    -- 9-15 randomize them, once held the scene save's half second (#443)
    pattern_row = 15,
    randomize_first_column = 9,
    pattern_hold_seconds = S.constants.GRID_HOLD.scene_save_seconds,
    pattern_key_level = 2,
    pattern_pending_level = 15,  -- while the hold is pending
  }

  -- Row 15's key at column x: once held LAYOUT_256.pattern_hold_seconds
  -- (through on_hold: a release, the grid's removal or cleanup cancels it),
  -- clear voice x's pattern (columns 1-7) or randomize voice x - 8's (9-15),
  -- then redraw the grids and the screen (SEQ shows the patterns). A press
  -- alone changes nothing; a key off row 15 or columns 1-7 and 9-15 does
  -- nothing
  local function pattern_key(port, x, y)
    if y ~= LAYOUT_256.pattern_row then return end
    local operation
    local randomize_voice = x - LAYOUT_256.randomize_first_column + 1
    if x >= 1 and x <= NUM_VOICES then
      operation = function() clear_pattern(x) end
    elseif randomize_voice >= 1 and randomize_voice <= NUM_VOICES then
      operation = function() randomize_pattern(randomize_voice) end
    else
      return
    end
    grid_core.on_hold(port, x, y, LAYOUT_256.pattern_hold_seconds, function()
      operation()
      grid_redraw()
      request_redraw()
    end)
  end

  -- Row 15's key LED at column x: 15 while its hold is pending, 2 otherwise
  local function pattern_key_level(port, x)
    local pending = grid_core.hold_pending(port, x, LAYOUT_256.pattern_row)
    return pending and LAYOUT_256.pattern_pending_level or LAYOUT_256.pattern_key_level
  end

  -- 16x16 grid layout
  function grid_key_256(port, x, y, z)
    local page = grid_core.page(port)
    if page == LAYOUT_256.positions_page and y ~= 8 and y ~= 16 then
      -- Page 5: positions on rows 1-7, each voice's strip on row 8 + v
      -- (presses and releases: a held key makes a loop or a hold)
      local strip_voice = y - LAYOUT_256.strip_first_row + 1
      if y <= NUM_VOICES then
        S.lib.positions.grid_key(port, y, x, 16, z)
      elseif strip_voice >= 1 and strip_voice <= NUM_VOICES and LAYOUT_256.strip_key_columns[x] then
        S.lib.positions.strip_key(port, strip_voice, LAYOUT_256.strip_key_columns[x], z)
      end
      return
    end
    if z == 0 then return end  -- presses only
    if y == 8 and x == LAYOUT_256.positions_key_column then
      grid_core.set_page(port, LAYOUT_256.positions_page)
      return
    end
    -- Handle page navigation first (always accessible from row 8)
    if y == 8 and x >= 13 and x <= 16 then
      -- Page selection (always accessible)
      grid_core.set_page(port, x - 12)
      return
    end

    if page == 3 then
      -- Scene page: the scene keys on rows 1-5; rows 8 and 16 work as on
      -- page 1 (#442)
      if y == 1 and x <= NUM_SCENES then
        -- Row 1: Scene recall (instant)
        recall_scene(x, 0)
      elseif y == 2 and x <= NUM_SCENES then
        -- Row 2: Scene recall (with transition)
        recall_scene(x, params:get("scene_transition_time"))
      elseif y == 3 and x <= NUM_SCENES then
        -- Row 3: Scene save, once held
        grid_core.scene_save_key(port, x, y, z, x)
      elseif y == 5 then
        -- Row 5: Scene sequencer controls
        if x == 1 then
          -- Toggle sequencer
          local enabled = params:get("scene_sequencer_enabled")
          params:set("scene_sequencer_enabled", enabled == 1 and 0 or 1)
        elseif x >= 3 and x <= 2 + NUM_SCENES then
          -- Set sequence length
          params:set("scene_sequence_length", x - 2)
        end
      elseif y == 8 then
        grid_key_256_transport(x)
      elseif y == 16 then
        grid_key_256_lock(port, x)
      end
    elseif page == 4 then
      -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
      -- sources on rows 9-15; rows 8 and 16 work as on page 1
      local fx_param_id = GRID_LAYOUT.fx_fader_ids[y - GRID_LAYOUT.fx_first_row + 1]
      local source_voice = y - GRID_LAYOUT.source_first_row + 1
      if y == GRID_LAYOUT.buffer_record_row then
        -- record into buffer x, or stop its recording early
        grid_core.record_key(x)
      elseif y == GRID_LAYOUT.buffer_clear_row then
        grid_core.clear_key(x)
      elseif fx_param_id then
        set_param_from_column(fx_param_id, x)
      elseif source_voice >= 1 and source_voice <= NUM_VOICES then
        if x == LAYOUT_256.freeze_column then
          S.lib.freeze.toggle(source_voice)
        else
          grid_core.source_key(source_voice, x)
        end
      elseif y == 8 then
        grid_key_256_transport(x)
      elseif y == 16 then
        grid_key_256_lock(port, x)
      end
    elseif y >= 1 and y <= NUM_VOICES then
      -- Rows 1-NUM_VOICES: Pattern triggers for each voice
      grid_core.step_key(port, x, y, z, y, x, x, PATTERN_LENGTH)
    elseif y == 8 then
      grid_key_256_transport(x)
    elseif y >= GRID_LAYOUT.fader_first_row and y < GRID_LAYOUT.fader_first_row + GRID_LAYOUT.fader_rows then
      -- Rows 9-12 (parameter page): one fader per row for the selected voice
      if page == 2 then
        local fader_index = (S.param_page - 1) * GRID_LAYOUT.fader_rows + (y - GRID_LAYOUT.fader_first_row + 1)
        set_fader_param(S.grid_voice_select, fader_index, x)
      end
    elseif y == GRID_LAYOUT.param_page_row then
      -- Row 13 (parameter page): choose which group of four faders is shown
      if page == 2 and x <= fader_page_count(S.grid_voice_select) then
        S.param_page = x
      end
    elseif y == 14 then
      -- Row 14: Voice selection for parameters (columns 1-7), voice
      -- on/off (columns 9-15)
      if x <= NUM_VOICES then
        select_grid_voice(x)
      elseif x >= 9 and x <= 8 + NUM_VOICES then
        toggle_voice(x - 8)
      end
    elseif y == LAYOUT_256.pattern_row then
      -- Row 15: Pattern operations (clear, randomize), once held
      pattern_key(port, x, y)
    elseif y == 16 then
      grid_key_256_lock(port, x)
    end
  end

  -- 256 row 8: pattern controls (page selection is handled by grid_key_256)
  function grid_key_256_transport(x)
    if x <= 4 then
      -- Play/stop
      pattern_toggle()
    elseif LAYOUT_256.tempo_steps[x] then
      -- Tempo -10, -1, +1, +10; the header shows the tempo it lands on
      params:delta("tempo", LAYOUT_256.tempo_steps[x])
      header_flash(string.format("tempo %d", util.round(params:get("tempo"))))
    end
  end

  -- Row 16, columns 9-15 (voices 1-7): with nothing copied, copy the voice's
  -- pattern (a snapshot of its levels); with a pattern copied, paste it onto
  -- the voice (the copied voice itself changes nothing). The clipboard stays
  -- for further pastes until column 16 clears it. A paste ends the voice's
  -- step-level gesture on every grid (a step held from before takes no level)
  local function copy_paste_key(port, voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    local state = grid_core.port_state(port)
    local clipboard = state.clipboard
    if clipboard == nil then
      local steps = {}
      for step = 1, PATTERN_LENGTH do steps[step] = S.patterns[voice_idx][step] end
      state.clipboard = {voice = voice_idx, steps = steps}
    elseif clipboard.voice ~= voice_idx then
      S.lib.sequencer.replace_pattern(voice_idx, clipboard.steps)
    end
  end

  -- Whether row 16's freeze key (column 8) is held on this port: columns
  -- 1-7 then freeze instead of lock
  local function freeze_held(port)
    return grid_core.held(port, LAYOUT_256.freeze_hold_column, 16) ~= nil
  end

  -- A freeze key's LED: 15 frozen, 3 not
  local function freeze_level(voice_idx)
    return S.lib.freeze.is_frozen(voice_idx) and LAYOUT_256.frozen_level or LAYOUT_256.unfrozen_level
  end

  -- 256 row 16: lock (columns 1-7; freeze while column 8 is held),
  -- copy/paste (9-15), clear the clipboard (16)
  function grid_key_256_lock(port, x)
    if x <= NUM_VOICES then
      if freeze_held(port) then S.lib.freeze.toggle(x) else toggle_lock(x) end
    elseif x == LAYOUT_256.clear_column then
      grid_core.port_state(port).clipboard = nil
    elseif x >= LAYOUT_256.copy_first_column then
      copy_paste_key(port, x - LAYOUT_256.copy_first_column + 1)
    end
  end

  function grid_redraw_256(port, grid_device)
    local page = grid_core.page(port)
    if page == LAYOUT_256.positions_page then
      -- Page 5: each voice's 16 positions (rows 1-7), its strip on row
      -- 8 + v, rows 8 and 16 as on pages 1-4
      for voice_idx = 1, NUM_VOICES do
        for cell = 1, 16 do
          grid_device:led(cell, voice_idx, S.lib.positions.grid_level(voice_idx, cell, 16))
        end
        local y = LAYOUT_256.strip_first_row + voice_idx - 1
        for x, key in pairs(LAYOUT_256.strip_key_columns) do
          grid_device:led(x, y, S.lib.positions.strip_level(voice_idx, key, port))
        end
      end
      grid_redraw_256_transport(port, grid_device)
      grid_redraw_256_lock(port, grid_device)
    elseif page == 3 then
      -- Scene page (rows 8 and 16 as on page 1)
      -- Row 1: Scene recall (instant). The scene the running sequencer
      -- recalls next at 10 (#303), the current scene at 15
      local next_slot = S.lib.scenes.sequencer_next_slot()
      for i = 1, NUM_SCENES do
        local brightness = S.scenes[i].populated and 8 or 2
        if i == next_slot then brightness = LAYOUT_256.sequencer_next_level end
        if S.lib.scenes.shows_current(i) then brightness = 15 end
        grid_device:led(i, 1, brightness)
      end

      -- Row 2: Scene recall (with transition)
      for i = 1, NUM_SCENES do
        local brightness = S.scenes[i].populated and 6 or 2
        grid_device:led(i, 2, brightness)
      end

      -- Row 3: Scene save (15 while a save is held)
      for i = 1, NUM_SCENES do
        grid_device:led(i, 3, grid_core.hold_pending(port, i, 3) and 15 or 4)
      end

      -- Row 5: Scene sequencer controls
      grid_device:led(1, 5, S.scene_sequencer_enabled and 15 or 4)  -- Sequencer on/off

      -- Sequence length indicators
      local seq_length = params:get("scene_sequence_length")
      for i = 1, NUM_SCENES do
        grid_device:led(i + 2, 5, i <= seq_length and 8 or 2)
      end

      grid_redraw_256_transport(port, grid_device)
      grid_redraw_256_lock(port, grid_device)
    elseif page == 4 then
      -- BUFFER / FX page: buffer rows 1-2, FX faders on rows 3-7, voice
      -- sources on rows 9-15, rows 8 and 16 as on page 1
      grid_redraw_256_buffers(grid_device)
      for index, param_id in ipairs(GRID_LAYOUT.fx_fader_ids) do
        grid_redraw_fader_row(grid_device, GRID_LAYOUT.fx_first_row + index - 1, param_id)
      end
      grid_redraw_256_sources(grid_device)
      grid_redraw_256_transport(port, grid_device)
      grid_redraw_256_lock(port, grid_device)
    else
      -- Patterns/parameters pages
      -- Draw patterns (rows 1-NUM_VOICES)
      for voice_idx = 1, NUM_VOICES do
        for step = 1, PATTERN_LENGTH do
          local brightness = step_brightness(voice_idx, step)
          grid_device:led(step, voice_idx, brightness)
        end
      end

      grid_redraw_256_transport(port, grid_device)

      -- Rows 9-13 (parameter page): faders and fader page selection
      if page == 2 then
        grid_redraw_faders(grid_device)
      end

      -- Row 14: Voice status
      for i = 1, NUM_VOICES do
        grid_device:led(i, 14, i == S.grid_voice_select and 15 or 4)
        grid_device:led(i + 8, 14, S.voices[i].active and 12 or 2)
      end

      -- Row 15: the clear and randomize keys (15 while a hold is pending)
      for i = 1, NUM_VOICES do
        local randomize_x = LAYOUT_256.randomize_first_column + i - 1
        grid_device:led(i, LAYOUT_256.pattern_row, pattern_key_level(port, i))
        grid_device:led(randomize_x, LAYOUT_256.pattern_row, pattern_key_level(port, randomize_x))
      end

      grid_redraw_256_lock(port, grid_device)
    end
  end

  -- 256 page 4, rows 1-2: buffer state (15 recording, 8 loaded, 2 empty)
  -- above each slot's clear key
  function grid_redraw_256_buffers(grid_device)
    for slot = 1, NUM_BUFFERS do
      grid_device:led(slot, GRID_LAYOUT.buffer_record_row, grid_core.record_level(slot))
      grid_device:led(slot, GRID_LAYOUT.buffer_clear_row, grid_core.CLEAR_LEVEL)
    end
  end

  -- 256 page 4, rows 9-15: each voice's source (selected 15, others 4, empty
  -- buffers 2) and, in column 12, its freeze key
  function grid_redraw_256_sources(grid_device)
    for voice_idx = 1, NUM_VOICES do
      local y = GRID_LAYOUT.source_first_row + voice_idx - 1
      for source = 1, #SOURCE_OPTIONS do
        grid_device:led(source, y, grid_core.source_level(voice_idx, source))
      end
      grid_device:led(LAYOUT_256.freeze_column, y, freeze_level(voice_idx))
    end
  end

  -- 256 row 8, columns 13-16: page indicators
  function grid_redraw_256_page_row(port, grid_device)
    local page = grid_core.page(port)
    for i = 1, 4 do
      grid_device:led(12 + i, 8, i == page and 15 or 2)
    end
    grid_device:led(LAYOUT_256.positions_key_column, 8,
      page == LAYOUT_256.positions_page and 15 or LAYOUT_256.positions_key_level)
  end

  -- 256 row 8: pattern controls, tempo and page indicators
  function grid_redraw_256_transport(port, grid_device)
    -- columns 1-4 all act as play/stop
    for x = 1, 4 do
      grid_device:led(x, 8, S.pattern_playing and 15 or 4)
    end

    -- Tempo keys: lit while held
    for x in pairs(LAYOUT_256.tempo_steps) do
      local held = grid_core.held(port, x, 8) ~= nil
      grid_device:led(x, 8, held and LAYOUT_256.tempo_held_level or LAYOUT_256.tempo_level)
    end

    grid_redraw_256_page_row(port, grid_device)
  end

  -- 256 row 16: lock status (columns 1-7; while column 8 is held, freeze
  -- status), the freeze key (8) and the clipboard (9-16): the copied voice
  -- 15, the paste targets and the clear key 4, 2 with nothing copied
  function grid_redraw_256_lock(port, grid_device)
    local holding = freeze_held(port)
    for i = 1, NUM_VOICES do
      if holding then
        grid_device:led(i, 16, freeze_level(i))
      else
        grid_device:led(i, 16, S.frozen[i] and 12 or 2)
      end
    end
    grid_device:led(LAYOUT_256.freeze_hold_column, 16,
      holding and LAYOUT_256.freeze_hold_level or LAYOUT_256.freeze_key_level)
    local clipboard = grid_core.port_state(port).clipboard
    for voice_idx = 1, NUM_VOICES do
      local level = LAYOUT_256.empty_level
      if clipboard then
        level = clipboard.voice == voice_idx and LAYOUT_256.copied_level or LAYOUT_256.paste_level
      end
      grid_device:led(LAYOUT_256.copy_first_column + voice_idx - 1, 16, level)
    end
    grid_device:led(LAYOUT_256.clear_column, 16, clipboard and LAYOUT_256.paste_level or LAYOUT_256.empty_level)
  end

  -- fx_faders_page: the page with the FX faders (rows 3-7 of page 4), so FX
  -- changes redraw the grids only while a 256 shows it (grid_core.any_fx_faders)
  S.registry.grid_layouts["256"] = {key = grid_key_256, redraw = grid_redraw_256, fx_faders_page = 4}

  return M
end

-- lib/grid/layout_64.lua
-- The 8x8 grid: one half of the patterns at a time (steps 1-8 or 9-16, per
-- port in S.lib.grid_core.port_state(port).half), or the positions view (grid
-- page 5: the grid voice's 16 positions, the bookmark strip, the voice
-- picker), keys and LEDs. Row 8 column 1's hold cycles the three. Registers
-- S.registry.grid_layouts["64"]. The functions stay global.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local GRID_HOLD = S.constants.GRID_HOLD
  local grid_core = S.lib.grid_core

  -- The 64's geometry and LED levels
  local LAYOUT_64 = {
    control_row = 8,
    play_column = 1,          -- tap: play / stop on release; hold: switch the half
    first_voice_column = 2,   -- columns 2-8: voices 1-7
    play_level = 15,          -- playing in the shown half
    blink_levels = {12, 3},   -- playing in the other half: odd / even beats
    steps_per_beat = 4,       -- a step is a sixteenth note: the blink follows quarter notes
    stopped_levels = {4, 8},  -- stopped: steps 1-8 shown dim, steps 9-16 brighter
    positions_page = 5,       -- the grid page of the positions view
    position_rows = {1, 2},   -- 16 cells: row 1 cells 1-8, row 2 cells 9-16
    strip_row = 3,
    strip_keys = {[1] = 1, [2] = 2, [3] = 3, [4] = 4, [6] = "store", [7] = "hold", [8] = "whole"},
    voice_row = 7,            -- columns 1-7 pick the grid voice
    positions_play_levels = {playing = 15, stopped = 6},
    voice_levels = {selected = 15, buffer = 6, other = 2},
    dark = 0,
    voice_toggle_levels = {on = 12, off = 4},
  }
  M.LAYOUT = LAYOUT_64

  -- Steps shown at once (the grid's width) and how many halves that makes
  local function visible_steps(cols)
    return math.min(PATTERN_LENGTH, cols)
  end

  local function half_count(cols)
    return math.ceil(PATTERN_LENGTH / visible_steps(cols))
  end

  -- The half the port shows (1 steps 1-8, 2 steps 9-16)
  function M.shown_half(port)
    return grid_core.port_state(port).half or 1
  end

  -- The step column x shows on the port
  local function shown_step(port, x, cols)
    return (M.shown_half(port) - 1) * visible_steps(cols) + x
  end

  local function positions_view(port)
    return grid_core.page(port) == LAYOUT_64.positions_page
  end

  -- The hold's cycle: steps 1-8, steps 9-16, positions, steps 1-8. It ends
  -- the port's step-level gesture, so a step held in the half it leaves
  -- never takes a level (#242)
  local function switch_half(port, cols)
    local state = grid_core.port_state(port)
    grid_core.end_port_step_gestures(port)
    if positions_view(port) then
      grid_core.set_page(port, 1)
      state.half = 1
    elseif M.shown_half(port) >= half_count(cols) then
      grid_core.set_page(port, LAYOUT_64.positions_page)
    else
      state.half = M.shown_half(port) + 1
    end
  end

  -- Row 8 column 1: a press starts the half-toggle hold; a release before it
  -- fires plays or stops. Once the hold fires the key is consumed, so its
  -- release does nothing; a release with no press seen (the grid was
  -- plugged in mid-press) does nothing either
  local function play_key(port, z, cols)
    local x, y = LAYOUT_64.play_column, LAYOUT_64.control_row
    if z == 1 then
      grid_core.on_hold(port, x, y, GRID_HOLD.half_toggle_seconds, function()
        switch_half(port, cols)
        grid_core.consume(port, x, y)
        grid_redraw()
      end)
    elseif grid_core.held(port, x, y) ~= nil then
      pattern_toggle()
    end
  end

  -- The positions view's keys (not row 8): rows 1-2 the grid voice's
  -- positions, row 3 its strip, row 7 the voice picker. Releases reach
  -- positions too, they end its holds
  local function positions_key(port, x, y, z)
    local voice_idx = S.grid_voice_select
    if y == LAYOUT_64.position_rows[1] or y == LAYOUT_64.position_rows[2] then
      local cell = (y - LAYOUT_64.position_rows[1]) * visible_steps(S.grids[port].cols) + x
      S.lib.positions.grid_key(port, voice_idx, cell, PATTERN_LENGTH, z)
    elseif y == LAYOUT_64.strip_row then
      local key = LAYOUT_64.strip_keys[x]
      if key then S.lib.positions.strip_key(port, voice_idx, key, z) end
    elseif y == LAYOUT_64.voice_row and z == 1 and x >= 1 and x <= NUM_VOICES then
      select_grid_voice(x)
    end
  end

  -- 8x8 grid layout (64 buttons)
  function grid_key_64(port, x, y, z)
    local cols = S.grids[port].cols
    if y == LAYOUT_64.control_row and x == LAYOUT_64.play_column then
      play_key(port, z, cols)
      return
    end
    if positions_view(port) and y ~= LAYOUT_64.control_row then
      positions_key(port, x, y, z)
      return
    end
    if z == 0 then return end  -- every other key acts at press
    if y >= 1 and y <= NUM_VOICES then
      -- Rows 1-7: the shown half's steps; levels follow its columns
      local positions = visible_steps(cols)
      grid_core.step_key(port, x, y, z, y, shown_step(port, x, cols), x, positions)
    elseif y == LAYOUT_64.control_row then
      local voice_idx = x - LAYOUT_64.first_voice_column + 1
      if voice_idx >= 1 and voice_idx <= NUM_VOICES then toggle_voice(voice_idx) end
    end
  end

  -- Column 1 of row 8: stopped, the shown half's level (4 for steps 1-8, 8
  -- for 9-16); the sounding step in the shown half bright; in the other
  -- half, a blink that alternates with the beat (every four steps). Playing
  -- with no step sounded yet counts as step 1
  local function play_level(port, cols)
    if not S.pattern_playing then
      return LAYOUT_64.stopped_levels[M.shown_half(port)] or LAYOUT_64.stopped_levels[1]
    end
    local sounding = S.lib.sequencer.sounding_step() or 1
    local playing_half = math.ceil(sounding / visible_steps(cols))
    if playing_half == M.shown_half(port) then return LAYOUT_64.play_level end
    local beat = math.ceil(sounding / LAYOUT_64.steps_per_beat)
    return LAYOUT_64.blink_levels[(beat + 1) % 2 + 1]
  end

  local function voice_toggle_level(voice_idx)
    return S.voices[voice_idx].active and LAYOUT_64.voice_toggle_levels.on or LAYOUT_64.voice_toggle_levels.off
  end

  local function positions_redraw(port, grid_device)
    local voice_idx = S.grid_voice_select
    local width = visible_steps(grid_device.cols)
    for row = 1, #LAYOUT_64.position_rows do
      for x = 1, width do
        local cell = (row - 1) * width + x
        grid_device:led(x, LAYOUT_64.position_rows[row], S.lib.positions.grid_level(voice_idx, cell, PATTERN_LENGTH))
      end
    end
    for x = 1, width do
      local key = LAYOUT_64.strip_keys[x]
      grid_device:led(x, LAYOUT_64.strip_row, key and S.lib.positions.strip_level(voice_idx, key) or LAYOUT_64.dark)
    end
    for y = LAYOUT_64.strip_row + 1, LAYOUT_64.voice_row - 1 do
      for x = 1, width do grid_device:led(x, y, LAYOUT_64.dark) end
    end
    for i = 1, NUM_VOICES do
      local level = LAYOUT_64.voice_levels.other
      if i == voice_idx then level = LAYOUT_64.voice_levels.selected
      elseif voice_uses_buffer(i) then level = LAYOUT_64.voice_levels.buffer end
      grid_device:led(i, LAYOUT_64.voice_row, level)
    end
    grid_device:led(LAYOUT_64.play_column, LAYOUT_64.control_row,
      S.pattern_playing and LAYOUT_64.positions_play_levels.playing or LAYOUT_64.positions_play_levels.stopped)
    for i = 1, NUM_VOICES do
      grid_device:led(LAYOUT_64.first_voice_column + i - 1, LAYOUT_64.control_row, voice_toggle_level(i))
    end
  end

  function grid_redraw_64(port, grid_device)
    if positions_view(port) then positions_redraw(port, grid_device); return end
    -- Rows 1-7: the shown half of each 16-step pattern (step_brightness
    -- lights the sounding step when it is in this half); the sequencer
    -- still plays all PATTERN_LENGTH steps
    local cols = grid_device.cols
    for voice_idx = 1, NUM_VOICES do
      for x = 1, visible_steps(cols) do
        grid_device:led(x, voice_idx, step_brightness(voice_idx, shown_step(port, x, cols)))
      end
    end

    -- Row 8: play / half, voices 1-7
    grid_device:led(LAYOUT_64.play_column, LAYOUT_64.control_row, play_level(port, cols))
    for i = 1, NUM_VOICES do
      grid_device:led(LAYOUT_64.first_voice_column + i - 1, LAYOUT_64.control_row, voice_toggle_level(i))
    end
  end

  S.registry.grid_layouts["64"] = {key = grid_key_64, redraw = grid_redraw_64}

  return M
end

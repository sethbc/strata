-- lib/grid/pages/patterns.lua
-- Grid page 1, patterns (3.8, design §10.3), two sides since 3.9 (the
-- grid sequencer's package 3b, design section 4). Side 1: seven lines of
-- sixteen steps, a line per voice. A step key goes through the pane's
-- step_key (a toggle at its release, the step editor after
-- GRID_HOLD.step_edit_seconds; 5a: a second key of the line before the
-- hold fires loops the voice between the two, S.lib.loop_roll.set_loop,
-- held by the first key's pane.still); a press also picks its voice for
-- side 2. Its LEDs are S.lib.lanes.hit_light, the picked voice's empty
-- steps at 1, a looped voice's set steps outside its loop at 2. Side 2, the lane side: the picked voice's hits (line 1, a
-- step key whose second key sets the level, or value A in move), its five
-- lanes' cells (lines 2-6, cell keys: a tap clears or gives the lane's
-- last value, a second key sets the held cell from its place) and the
-- utility line (the mode, LN, the targets, B and the seven voices).
-- The picked voice, the lanes' last values and LN's arming are the port's
-- page state (pane.state()'s table). Written in pane coordinates
-- (lib/grid/pane.lua), so it is the same on every layout. See
-- docs/notes/lua/grid/pages/patterns.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local GRID_PAGES = S.constants.GRID_PAGES
  local GRID_LEVELS = S.constants.GRID_LEVELS

  -- Side 2 (design section 4, Side 2): each line's lane (line 1 the hits,
  -- lines 2-6 S.lib.lanes.LANES), the utility line and its keys (x 1-3
  -- the modes, LN, the four targets from first_target_x in
  -- S.lib.lanes.TARGETS' order, B, the voices from first_voice_x), B's
  -- key role, the port state's key pane.state() keeps its pages under,
  -- what a tap gives an empty cell before any value is set on the lane
  -- (chance: 8 of 15 keys, round(8 * 100 / 15); gate: the voice's gate
  -- length), the lights
  local LANE_SIDE = {
    side = 2,
    lines = {"hits", "a", "b", "chance", "repeats", "gate"},
    utility_line = 7,
    modes = {"pulse", "move", "accent"},
    ln_x = 4, first_target_x = 5, b_x = 9, first_voice_x = 10,
    b_role = "patterns B",
    pages_key = "pages",
    tap_first = {a = MAX_STEP_LEVEL, b = MAX_STEP_LEVEL, chance = 53, repeats = 2},
    max_prob = 100, max_repeats = 4,
    levels = {
      picked_empty = 1,                       -- side 1: the picked voice's empty steps
      outside_loop = 2,                       -- side 1: a looped voice's set steps outside its loop (at most)
      repeats = {4, 8, 11, 15},               -- 1 to 4 repeats
      playing = 15, playing_empty = 4,        -- the cell a lane read last
      past_length = 1,                        -- a cell past its lane's length that holds something
      shadowed = 2,                           -- value B's cells where B names A's target
      mode_on = 15, mode_off = 4, gate_pulse = 8,
      ln_armed = 15, ln_off = 4, ln_length = 8, ln_following = 3,
      target_a = 15, target_auto = 10, target_b = 8, target_other = 2,
      b_held = 15, b_on = 8, b_off = 2,
    },
  }
  M.LANE_SIDE = LANE_SIDE

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx == math.floor(voice_idx) and voice_idx >= 1
      and voice_idx <= NUM_VOICES
  end

  local function valid_cell(cell)
    return type(cell) == "number" and cell == math.floor(cell) and cell >= 1 and cell <= PATTERN_LENGTH
  end

  local function voice_param(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  -- The voice's length from the voices table (the only source of values, as
  -- the sequencer reads it), so a draw before the params exist still works
  local function voice_length(voice_idx)
    return (S.voices[voice_idx].values or {}).seq_length or PATTERN_LENGTH
  end

  -- The port's state of this page, pane.state()'s table
  -- (port_state(port).pages.patterns): made with `create`, else nil while
  -- the port has none
  local function page_state(port, create)
    local core = S.lib.grid_core
    local port_state = create and core.port_state(port) or core.existing_port_state(port)
    if port_state == nil then return nil end
    local name = GRID_PAGES.names[GRID_PAGES.patterns]
    if create then
      port_state[LANE_SIDE.pages_key] = port_state[LANE_SIDE.pages_key] or {}
      port_state[LANE_SIDE.pages_key][name] = port_state[LANE_SIDE.pages_key][name] or {}
    end
    local pages = port_state[LANE_SIDE.pages_key]
    return pages and pages[name]
  end

  -- The port's picked voice (side 2 shows its lanes): 1 until a pick
  function M.voice(port)
    local state = page_state(port)
    local voice_idx = state and state.voice
    if valid_voice(voice_idx) then return voice_idx end
    return 1
  end

  -- Pick the port's voice (a press on side 1, a voice key of side 2). A
  -- port with no grid or a voice out of range does nothing
  function M.pick(port, voice_idx)
    if S.grids[port] == nil or not valid_voice(voice_idx) then return end
    page_state(port, true).voice = voice_idx
    grid_redraw()
  end

  -- Values ------------------------------------------------------------------
  -- (module functions: 3.9's 3c, the step view, sets and lights a step's
  -- cells with them)

  -- The value a key at position (1..positions along the keys shown) gives
  -- a lane: hits, value A and B the level (S.lib.grid_core's
  -- level_for_position); chance that level's share of 100; repeats
  -- 1 to 4 spread over the keys; gate the level's place of fifteen equal
  -- steps on the voice's gate length spec. nil for no lane
  function M.value_for_position(voice_idx, lane, position, positions)
    if not valid_voice(voice_idx) then return nil end
    local level = S.lib.grid_core.level_for_position(position, positions)
    if lane == "hits" or lane == "a" or lane == "b" then return level end
    if lane == "chance" then return util.round(level * LANE_SIDE.max_prob / MAX_STEP_LEVEL) end
    if lane == "repeats" then
      return util.clamp(math.max(1, util.round(position * LANE_SIDE.max_repeats / positions)), 1, LANE_SIDE.max_repeats)
    end
    if lane == "gate" then
      local spec = params:lookup_param(voice_param(voice_idx, "seq_gate_length")).controlspec
      return util.clamp(spec:map((level - 1) / (MAX_STEP_LEVEL - 1)), spec.minval, spec.maxval)
    end
    return nil
  end

  -- A step's value written on side 2 (the controller's ruling for 3b's
  -- review): a value set on a step that is off turns it on at a tap's level
  -- (MAX_STEP_LEVEL, through the one writer of a level), since a value on
  -- an off step is never played nor shown. A step's value is value A or B
  -- in a lane that follows (a free lane's cell is no step's: its hits are
  -- left alone), and value A from the hits line in move
  local function value_turns_on(voice_idx, lane, cell)
    if S.patterns[voice_idx][cell] ~= 0 then return end
    local follows = (lane == "a" or lane == "b") and S.lib.lanes.length(voice_idx, lane) == nil
    if follows or lane == "hits" then S.lib.sequencer.set_level(voice_idx, cell, MAX_STEP_LEVEL) end
  end

  -- Set a step's cell from a key's position: the hits' level (in move its
  -- value A, the level left as it is), or the lane's step key; a value on
  -- an off step turns it on (value_turns_on)
  function M.set_from_position(voice_idx, lane, cell, position, positions)
    local value = M.value_for_position(voice_idx, lane, position, positions)
    if value == nil or not valid_cell(cell) then return nil end
    local seq = S.lib.sequencer
    if lane == "hits" then
      if seq.step_mode(voice_idx) == "move" then
        seq.set_step_attr(voice_idx, cell, S.lib.lanes.STEP_KEYS.a, value)
        value_turns_on(voice_idx, lane, cell)
      else
        seq.set_level(voice_idx, cell, value)
      end
    else
      seq.set_step_attr(voice_idx, cell, S.lib.lanes.STEP_KEYS[lane], value)
      value_turns_on(voice_idx, lane, cell)
    end
    return value
  end

  -- What a lane's cell shows: its step key's value; for chance, a set step
  -- with no prob plays always (max_prob). nil for nothing
  local function shown_value(voice_idx, lane, cell)
    local value = S.lib.sequencer.step_attr(voice_idx, cell, S.lib.lanes.STEP_KEYS[lane])
    if value == nil and lane == "chance" and S.patterns[voice_idx][cell] > 0 then return LANE_SIDE.max_prob end
    return value
  end

  -- A lane value's light: value A and B their level; chance its share of
  -- 15 (at least 1); repeats LANE_SIDE.levels.repeats; gate its place of
  -- the fifteen on the gate length spec
  function M.value_light(voice_idx, lane, value)
    if value == nil or not valid_voice(voice_idx) then return 0 end
    if lane == "chance" then return math.max(1, util.round(value * MAX_STEP_LEVEL / LANE_SIDE.max_prob)) end
    if lane == "repeats" then return LANE_SIDE.levels.repeats[value] or 0 end
    if lane == "gate" then
      local spec = params:lookup_param(voice_param(voice_idx, "seq_gate_length")).controlspec
      return 1 + util.round(spec:unmap(value) * (MAX_STEP_LEVEL - 1))
    end
    return value
  end

  -- The option a lane's target param holds, by name (B's "off" among them)
  local function target_option(voice_idx, lane)
    local lanes = S.lib.lanes
    return lanes.options(lane)[params:get(voice_param(voice_idx, lanes.MOVE.param[lane]))]
  end

  -- Whether value B's lane does nothing because B names A's target
  local function b_shadowed(voice_idx)
    return target_option(voice_idx, "b") ~= S.lib.lanes.MOVE.first.b and S.lib.lanes.target(voice_idx, "b") == nil
  end

  -- A lane's length as side 2 shows it: its own while free, else the voice's
  local function shown_length(voice_idx, lane)
    if lane ~= "hits" then
      local n = S.lib.lanes.length(voice_idx, lane)
      if n then return n, true end
    end
    return voice_length(voice_idx), lane == "hits"
  end

  -- The cell a lane read last, while the voice plays: a free lane's own
  -- (S.lib.lanes.sounding), a following lane's the hits' sounding step
  local function playing_cell(voice_idx, lane)
    local step = S.lib.sequencer.sounding_step(voice_idx)
    if step == nil then return nil end
    if S.lib.lanes.length(voice_idx, lane) then return S.lib.lanes.sounding(voice_idx, lane) end
    return step
  end

  -- A lane cell's light on side 2 (lines 2-6): B's line at
  -- levels.shadowed where B names A's target; the cell the lane read last
  -- at 15 if it holds something, 4 if not; past the lane's length 1 if it
  -- holds something; else its value's light (0 for nothing)
  function M.cell_light(voice_idx, lane, cell)
    if not valid_voice(voice_idx) or not valid_cell(cell) or S.lib.lanes.STEP_KEYS[lane] == nil then return 0 end
    local value, levels = shown_value(voice_idx, lane, cell), LANE_SIDE.levels
    if lane == "b" and b_shadowed(voice_idx) then return value ~= nil and levels.shadowed or 0 end
    if cell == playing_cell(voice_idx, lane) then return value ~= nil and levels.playing or levels.playing_empty end
    if cell > shown_length(voice_idx, lane) then return value ~= nil and levels.past_length or 0 end
    return M.value_light(voice_idx, lane, value)
  end

  -- A mode key's light (side 2's utility line; 3.9's 5c lights the
  -- perform side's alike): the voice's mode 15, the others 4; a voice in
  -- gate (3.8's on) lights pulse at gate_pulse
  function M.mode_level(voice_idx, name)
    local mode, levels = S.lib.sequencer.step_mode(voice_idx), LANE_SIDE.levels
    if mode == name then return levels.mode_on end
    if mode == "gate" and name == "pulse" then return levels.gate_pulse end
    return levels.mode_off
  end

  -- LN ----------------------------------------------------------------------
  -- Armed by a tap of LN, the port's state holds the pane it was armed on
  -- and that pane's count of page changes then (S.lib.grid_core's
  -- page_changes, the controller's ruling for 3b's review: it moves at
  -- every page or side change, the 8×8's chooser's among them, and never
  -- at a half change). It reads as disarmed once the count has moved, so
  -- leaving side 2 by any way disarms it and a half change keeps it. The
  -- count replaces ruling 3b-2's page and side compare, which it implies

  -- Whether LN is armed on the port's pane
  function M.ln_armed(port, pane_index)
    local state = page_state(port)
    local ln = state and state.ln
    return ln ~= nil and ln.pane == pane_index and ln.changes == S.lib.grid_core.page_changes(port, pane_index)
  end

  local function disarm(port)
    local state = page_state(port)
    if state then state.ln = nil end
  end

  -- An armed LN's key of a lane's line: the lane's length set (the key at
  -- its length sets it back to following; line 1 sets the voice's length),
  -- then LN disarms
  local function set_length_key(pane, voice_idx, lane, x)
    if lane == "hits" then
      params:set(voice_param(voice_idx, "seq_length"), x)
    else
      local lanes = S.lib.lanes
      lanes.set_length(voice_idx, lane, lanes.length(voice_idx, lane) ~= x and x or nil)
    end
    disarm(pane.port)
  end

  -- Side 2's keys -------------------------------------------------------------

  -- A tap on a lane's cell: a cell that holds a value is cleared; an empty
  -- one takes the value last set on the lane on this port (before any:
  -- tap_first, gate the voice's gate length)
  local function tap_cell(port, voice_idx, lane, cell)
    local seq, key = S.lib.sequencer, S.lib.lanes.STEP_KEYS[lane]
    if seq.step_attr(voice_idx, cell, key) ~= nil then
      seq.set_step_attr(voice_idx, cell, key, nil)
      return
    end
    local state = page_state(port)
    local value = state and state.last and state.last[lane]
    if value == nil then
      value = LANE_SIDE.tap_first[lane] or params:get(voice_param(voice_idx, "seq_gate_length"))
    end
    seq.set_step_attr(voice_idx, cell, key, value)
    value_turns_on(voice_idx, lane, cell)
  end

  -- Set a step's cell from a key's position and keep the value as the
  -- port's last for the lane (a second key of side 2; a bar of the step view)
  local function set_and_remember(port, voice_idx, lane, cell, position, positions)
    local value = M.set_from_position(voice_idx, lane, cell, position, positions)
    if value == nil then return end
    local state = page_state(port, true)
    state.last = state.last or {}
    state.last[lane] = value
  end

  local function press_cell(pane, voice_idx, lane, x, y, z)
    local port = pane.port
    pane.cell_key(x, y, z, "patterns " .. voice_idx .. " " .. lane, x,
      function(cell) tap_cell(port, voice_idx, lane, cell) end,
      function(cell, position, positions) set_and_remember(port, voice_idx, lane, cell, position, positions) end)
  end

  -- The hits line's second key: the held step's level (value A in move)
  -- from the second key's place along this pane's keys shown
  local function hits_second(pane)
    return function(voice_idx, held_step, second_step)
      local position = second_step - pane.offset
      if position < 1 or position > pane.width then return end
      M.set_from_position(voice_idx, "hits", held_step, position, pane.width)
    end
  end

  local function press_utility(pane, voice_idx, x, z)
    if z ~= 1 then return end
    local line, lanes = LANE_SIDE.utility_line, S.lib.lanes
    local target = lanes.TARGETS[x - LANE_SIDE.first_target_x + 1]
    if LANE_SIDE.modes[x] then
      lanes.choose_mode(voice_idx, LANE_SIDE.modes[x])
    elseif x == LANE_SIDE.ln_x then
      if M.ln_armed(pane.port, pane.index) then
        disarm(pane.port)
      else
        page_state(pane.port, true).ln = {pane = pane.index,
          changes = S.lib.grid_core.page_changes(pane.port, pane.index)}
      end
    elseif target and x < LANE_SIDE.b_x then
      if pane.pressed_as(LANE_SIDE.b_x, line, LANE_SIDE.b_role) then
        lanes.choose_target(voice_idx, "b", target_option(voice_idx, "b") == target and lanes.MOVE.first.b or target)
      else
        lanes.choose_target(voice_idx, "a", target)
      end
    elseif x == LANE_SIDE.b_x then
      pane.press_as(x, line, LANE_SIDE.b_role)
    elseif x >= LANE_SIDE.first_voice_x then
      M.pick(pane.port, x - LANE_SIDE.first_voice_x + 1)
    end
  end

  local function press_lanes(pane, x, y, z)
    local voice_idx = M.voice(pane.port)
    if y == LANE_SIDE.utility_line then
      press_utility(pane, voice_idx, x, z)
      return
    end
    local lane = LANE_SIDE.lines[y]
    if z == 1 and M.ln_armed(pane.port, pane.index) then
      pane.consume(x, y)
      set_length_key(pane, voice_idx, lane, x)
      return
    end
    if lane == "hits" then
      pane.step_key(x, y, z, voice_idx, x, hits_second(pane))
    else
      press_cell(pane, voice_idx, lane, x, y, z)
    end
  end

  -- Side 2's lights ----------------------------------------------------------

  -- Armed LN's light of a lane's line at step: 8 up to a free lane's (and
  -- the hits') length, 3 up to the voice's for a following lane, else dark
  local function length_light(voice_idx, lane, step)
    local n, own = shown_length(voice_idx, lane)
    if step > n then return 0 end
    return own and LANE_SIDE.levels.ln_length or LANE_SIDE.levels.ln_following
  end

  local function target_level(voice_idx, target)
    local levels, lanes = LANE_SIDE.levels, S.lib.lanes
    if target == lanes.target(voice_idx, "a") then
      return target_option(voice_idx, "a") == lanes.MOVE.first.a and levels.target_auto or levels.target_a
    end
    if target == target_option(voice_idx, "b") then return levels.target_b end
    return levels.target_other
  end

  local function draw_utility(pane, led, voice_idx, armed)
    local line, levels = LANE_SIDE.utility_line, LANE_SIDE.levels
    for x, name in ipairs(LANE_SIDE.modes) do led(x, line, M.mode_level(voice_idx, name)) end
    led(LANE_SIDE.ln_x, line, armed and levels.ln_armed or levels.ln_off)
    for n, target in ipairs(S.lib.lanes.TARGETS) do
      led(LANE_SIDE.first_target_x + n - 1, line, target_level(voice_idx, target))
    end
    local b_level = target_option(voice_idx, "b") ~= S.lib.lanes.MOVE.first.b and levels.b_on or levels.b_off
    if pane.pressed_as(LANE_SIDE.b_x, line, LANE_SIDE.b_role) then b_level = levels.b_held end
    led(LANE_SIDE.b_x, line, b_level)
    for n = 1, NUM_VOICES do
      led(LANE_SIDE.first_voice_x + n - 1, line, n == voice_idx and GRID_LEVELS.picked or GRID_LEVELS.unpicked)
    end
  end

  local function draw_lanes(pane, led)
    local voice_idx = M.voice(pane.port)
    local armed = M.ln_armed(pane.port, pane.index)
    for y, lane in ipairs(LANE_SIDE.lines) do
      for step = 1, PATTERN_LENGTH do
        local level
        if armed then
          level = length_light(voice_idx, lane, step)
        elseif lane == "hits" then
          level = S.lib.lanes.hit_light(voice_idx, step)
        else
          level = M.cell_light(voice_idx, lane, step)
        end
        led(step, y, level)
      end
    end
    draw_utility(pane, led, voice_idx, armed)
  end

  -- The step view (3.9's 3c) --------------------------------------------------
  -- While S.lib.grid_core.step_view(port) names this pane (the step editor
  -- open from a key of the port; computed, never recorded), lines 1-6 are
  -- bars of the editor's step: its level and its cells in the five lanes
  -- (LANE_SIDE.lines' order), each lit `lit` from the first key shown to
  -- its value's key (value_key), dark beyond; a free lane's line, a lane
  -- with no value and line 7 are dark. A press on key x of a line sets the
  -- value from x as side 2's second key does; on a lane's own last key it
  -- clears the cell (value A and B none, chance 100, repeats 1, gate the
  -- voice's); line 1 sets the level only, a free lane's and line 7's keys
  -- nothing
  local STEP_VIEW = {lit = 10}

  -- The view, if it is this pane's
  function STEP_VIEW.of(pane)
    local view = S.lib.grid_core.step_view(pane.port)
    if view and view.pane == pane.index then return view end
    return nil
  end

  -- A bar's value: the step's level (nil while it is off); a lane's cell as
  -- side 2 shows it (shown_value); nil for a free lane
  function STEP_VIEW.value(voice_idx, lane, step)
    if lane == "hits" then
      local level = S.patterns[voice_idx][step]
      return level > 0 and level or nil
    end
    if S.lib.lanes.length(voice_idx, lane) then return nil end
    return shown_value(voice_idx, lane, step)
  end

  -- The position a value reaches: the first of 1..positions whose value
  -- (value_for_position) is at least it, the last for one above them all
  function STEP_VIEW.value_key(voice_idx, lane, value, positions)
    for position = 1, positions do
      if M.value_for_position(voice_idx, lane, position, positions) >= value then return position end
    end
    return positions
  end

  function STEP_VIEW.draw(pane, led, view)
    for y, lane in ipairs(LANE_SIDE.lines) do
      local value = STEP_VIEW.value(view.voice, lane, view.step)
      local to = value and STEP_VIEW.value_key(view.voice, lane, value, pane.width) or 0
      for position = 1, to do led(pane.offset + position, y, STEP_VIEW.lit) end
    end
  end

  function STEP_VIEW.press(pane, view, x, y, z)
    local lane = LANE_SIDE.lines[y]
    if z ~= 1 or lane == nil or not pane.shows(x) then return end
    local voice_idx, step, position = view.voice, view.step, x - pane.offset
    if lane == "hits" then
      S.lib.sequencer.set_level(voice_idx, step, S.lib.grid_core.level_for_position(position, pane.width))
      return
    end
    if S.lib.lanes.length(voice_idx, lane) then return end
    local value = shown_value(voice_idx, lane, step)
    if value ~= nil and STEP_VIEW.value_key(voice_idx, lane, value, pane.width) == position then
      S.lib.sequencer.set_step_attr(voice_idx, step, S.lib.lanes.STEP_KEYS[lane], nil)
      return
    end
    set_and_remember(pane.port, voice_idx, lane, step, position, pane.width)
  end

  -- Side 1 -------------------------------------------------------------------

  -- The picked voice's empty steps inside its length light picked_empty;
  -- past its length they stay dark (the controller's ruling for 3b's
  -- review), so the length shows. 5a (design section 4, Lights): while a
  -- voice has a loop, its set steps outside it but the playhead dim to
  -- outside_loop (never brighter than they were)
  local function draw_steps(pane, led)
    local picked = M.voice(pane.port)
    local picked_length = voice_length(picked)
    for voice_idx = 1, NUM_VOICES do
      local lo, hi = S.lib.loop_roll.loop(voice_idx)
      local sounding = S.lib.sequencer.sounding_step(voice_idx)
      for step = 1, PATTERN_LENGTH do
        local level = S.lib.lanes.hit_light(voice_idx, step)
        if voice_idx == picked and level == 0 and S.patterns[voice_idx][step] == 0 and step <= picked_length then
          level = LANE_SIDE.levels.picked_empty
        end
        if lo and (step < lo or step > hi) and S.patterns[voice_idx][step] > 0 and step ~= sounding then
          level = math.min(level, LANE_SIDE.levels.outside_loop)
        end
        led(step, voice_idx, level)
      end
    end
  end

  -- Side 1's second key (5a, design section 4, The loop): the voice loops
  -- between its held step and this key's, held by the held key's own
  -- still (its pane place, which pane.step_key gives); an armed latch keeps
  -- it (S.lib.loop_roll.set_loop)
  local function loop_second(pane)
    return function(voice_idx, held_step, second_step, held_x, held_y)
      S.lib.loop_roll.set_loop(voice_idx, held_step, second_step, pane.still(held_x, held_y))
    end
  end

  M.record = {
    name = "patterns",
    index = GRID_PAGES.patterns,
    sides = LANE_SIDE.side,
    press = function(pane, x, y, z)
      if y < 1 or y > NUM_VOICES or x < 1 or x > PATTERN_LENGTH then return end
      if pane.side == LANE_SIDE.side then
        local view = STEP_VIEW.of(pane)
        if view then
          STEP_VIEW.press(pane, view, x, y, z)
        else
          press_lanes(pane, x, y, z)
        end
        return
      end
      if z == 1 then M.pick(pane.port, y) end
      pane.step_key(x, y, z, y, x, loop_second(pane))
    end,
    redraw = function(pane, led)
      local view = pane.side == LANE_SIDE.side and STEP_VIEW.of(pane)
      if view then
        STEP_VIEW.draw(pane, led, view)
      elseif pane.side == LANE_SIDE.side then
        draw_lanes(pane, led)
      else
        draw_steps(pane, led)
      end
    end,
  }
  S.register_grid_page(M.record)

  return M
end

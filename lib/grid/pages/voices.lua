-- lib/grid/pages/voices.lua
-- Grid page 6, voices (3.8, design §10.8): line v is voice v. x 1-8 MU
-- (mute), SO (solo), LK (lock), FZ (freeze, quantized), CL and RN (clear
-- and randomize the voice's pattern, held half a second), PC (copy and
-- paste a whole pattern) and VC (copy one voice's sound to another, through
-- S.lib.voice_presets.copy); x 9-16 the voice's level (v<v>_amp), a fader
-- line of eight keys the pane engine sets and draws. Written in pane
-- coordinates (lib/grid/pane.lua), so it is the same on every layout; on
-- a 64 the left half is the eight keys, the right the level fader. Its
-- state (the pattern copy and the voice mark, per port) is pane.state()'s
--
-- CL and RN hold for GRID_HOLD.action_hold_seconds (0.5 s), the grids'
-- half-second hold (a recorder's clear waits it too). 3.9 (the grid
-- sequencer's 5c, design section 4, The perform side): a second side, a
-- line a voice: MU SO as side 1's, the letters A-D
-- (S.lib.pattern_letters.switch), OR (held: the letters tapped make a new
-- order, set at its release; tapped alone: the order on or off), LP (the
-- loop's latch, S.lib.loop_roll.press_latch), R1-R4 (held: a roll at that
-- rate, held by the key's own pane.still), the mode keys (pulse, move,
-- accent: S.lib.lanes.choose_mode) and FL (held: fill, holder
-- "grid:<port>:<line>"). Side 2 has no fader line

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local GRID_HOLD = S.constants.GRID_HOLD

  -- The keys of a line (pane x), the level line (its first key and its
  -- eight keys), the hold of CL and RN, and the levels
  local VOICES_PAGE = {
    keys = {mute = 1, solo = 2, lock = 3, freeze = 4, clear = 5, randomize = 6, pattern_copy = 7, voice_copy = 8},
    level_first = 9,
    level_keys = 8,
    hold_seconds = GRID_HOLD.action_hold_seconds,
    levels = {on = 15, off = 4, freeze_on = 15, freeze_off = 3, pending = 15, idle = 2,
      copied = 15, target = 4, no_copy = 2},
  }
  M.VOICES_PAGE = VOICES_PAGE

  -- The perform side (side 2): its keys (pane x), its mode keys' modes,
  -- the roles its held keys are pressed in, and the lights
  local PERFORM = {
    side = 2,
    keys = {mute = 1, solo = 2, first_letter = 3, order = 7, latch = 8, first_roll = 9, rolls = 4, fill = 16},
    modes = {[13] = "pulse", [14] = "move", [15] = "accent"},
    order_role = "perform order", fill_role = "perform fill",
    levels = {letter_playing = 15, letter_used = 4, letter_unused = 2,
      order_on = 15, order_off = 4, order_none = 2, order_held = 10,
      latch_off = 2, latch_held = 6, latch_armed = 10, latch_latched = 15,
      roll_on = 15, roll_off = 4, fill_on = 15, fill_off = 4},
  }
  M.PERFORM = PERFORM

  local keys, levels = VOICES_PAGE.keys, VOICES_PAGE.levels
  local HOLD_KEYS = {keys.clear, keys.randomize}

  local function whole_in(n, low, high)
    return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
  end

  local function param_of(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  local function exists(param_id) return params.lookup[param_id] ~= nil end

  local function is_on(param_id) return exists(param_id) and params:get(param_id) == 1 end

  local function toggle_param(param_id)
    if exists(param_id) then set_binary_param(param_id, params:get(param_id) == 1 and 0 or 1) end
  end

  -- CL and RN: the operation runs once the key has been held hold_seconds
  -- (a release before, or a page change of the pane, cancels it)
  local function hold_key(pane, x, voice_idx, operation)
    pane.on_hold(x, voice_idx, VOICES_PAGE.hold_seconds, function()
      operation(voice_idx)
      grid_redraw()
      request_redraw()
    end)
  end

  -- PC: no copy copies the voice's whole pattern (a snapshot,
  -- S.lib.sequencer.whole: its levels, steps' settings and lane lengths,
  -- 3.9's 4a); a copy of another voice is pasted over the playing one
  -- whole (replace_whole, which ends the voice's step gestures on every
  -- grid), and stays; the copied voice's key drops the copy
  local function pattern_copy_key(pane, voice_idx)
    local state = pane.state()
    local copy = state.patterns
    if copy == nil then
      state.patterns = {voice = voice_idx, pattern = S.lib.sequencer.whole(voice_idx)}
    elseif copy.voice == voice_idx then
      state.patterns = nil
    else
      S.lib.sequencer.replace_whole(voice_idx, copy.pattern)
    end
  end

  -- VC: no mark marks the voice; a mark of another voice copies that
  -- voice's sound, read now, into this one (S.lib.voice_presets.copy: its
  -- undo held for VOICE's ALT+K2; a refused copy changes nothing), and the
  -- mark stays; the marked voice's key drops the mark
  local function voice_copy_key(pane, voice_idx)
    local state = pane.state()
    local mark = state.sound
    if mark == nil then
      state.sound = {voice = voice_idx}
    elseif mark.voice == voice_idx then
      state.sound = nil
    else
      S.lib.voice_presets.copy(mark.voice, voice_idx)
    end
  end

  local function press_voice_keys(pane, x, y, z)
    if z ~= 1 or not whole_in(x, 1, keys.voice_copy) or not whole_in(y, 1, NUM_VOICES) then return end
    local voice_idx = y
    if x == keys.mute then
      toggle_param(param_of(voice_idx, "mute"))
    elseif x == keys.solo then
      toggle_param(param_of(voice_idx, "solo"))
    elseif x == keys.lock then
      toggle_lock(voice_idx)
    elseif x == keys.freeze then
      S.lib.freeze.toggle_quantized(voice_idx)
    elseif x == keys.clear then
      hold_key(pane, x, voice_idx, clear_pattern)
    elseif x == keys.randomize then
      hold_key(pane, x, voice_idx, randomize_pattern)
    elseif x == keys.pattern_copy then
      pattern_copy_key(pane, voice_idx)
    else
      voice_copy_key(pane, voice_idx)
    end
  end

  -- The perform side's keys ------------------------------------------------

  -- The letters A-D (S.lib.pattern_letters is included after this page,
  -- so read at each use)
  local function all_letters() return S.lib.pattern_letters.LETTERS end

  -- The letter of key x (A-D from first_letter), or nil
  local function letter_of(x) return all_letters()[x - PERFORM.keys.first_letter + 1] end

  -- The order being built while OR is held: the port's page state keeps,
  -- per voice, {pane, still (OR's own press), letters}; it counts only
  -- while OR's still holds, so it never outlives its key
  local function order_build(pane, voice_idx)
    local builds = pane.state().orders
    local build = builds and builds[voice_idx]
    if build and build.still() then return build end
    return nil
  end

  -- OR: a press starts a new order, empty; its release sets the order
  -- built (S.lib.pattern_letters.set_order, which turns it on from its
  -- first letter at the next bar), or with no letter tapped turns the
  -- voice's order on or off (set_order_on). Only the release of OR pressed
  -- as OR on this pane acts, so a page change before it does nothing
  local function order_key(pane, x, voice_idx, z)
    local state, letters = pane.state(), S.lib.pattern_letters
    if z == 1 then
      pane.press_as(x, voice_idx, PERFORM.order_role)
      state.orders = state.orders or {}
      state.orders[voice_idx] = {pane = pane.index, still = pane.still(x, voice_idx), letters = {}}
      return
    end
    local build = order_build(pane, voice_idx)
    if build == nil or build.pane ~= pane.index then return end
    state.orders[voice_idx] = nil
    if not pane.pressed_as(x, voice_idx, PERFORM.order_role) then return end
    if #build.letters > 0 then
      letters.set_order(voice_idx, build.letters)
    else
      letters.set_order_on(voice_idx, not select(2, letters.order(voice_idx)))
    end
  end

  -- A letter: added to the order OR builds while it is held (up to the
  -- order's max), else switched to (S.lib.pattern_letters.switch: it waits
  -- for the bar while the patterns play)
  local function letter_key(pane, voice_idx, letter)
    local build = order_build(pane, voice_idx)
    if build == nil then
      S.lib.pattern_letters.switch(voice_idx, letter)
    elseif #build.letters < S.lib.pattern_letters.VARIATIONS.max_order then
      build.letters[#build.letters + 1] = letter
    end
  end

  -- FL: held, fill, held by the key's own still under the line's holder;
  -- only its own release ends that hold
  local function fill_key(pane, x, voice_idx, z)
    local holder = "grid:" .. pane.port .. ":" .. voice_idx
    if z == 1 then
      pane.press_as(x, voice_idx, PERFORM.fill_role)
      S.lib.conditions.hold_fill(holder, true, pane.still(x, voice_idx))
    elseif pane.pressed_as(x, voice_idx, PERFORM.fill_role) then
      S.lib.conditions.hold_fill(holder, false)
    end
  end

  -- A roll key's rate (1..rolls from first_roll), or nil
  local function roll_rate(x)
    local rate = x - PERFORM.keys.first_roll + 1
    if rate >= 1 and rate <= PERFORM.keys.rolls then return rate end
    return nil
  end

  -- A key of side 2 (a release acts for OR and FL only). A roll key's
  -- press rolls the voice, held by the key's own still: its release (the
  -- press gone) ends that roll and no other, so the release itself does
  -- nothing, and a roll another key started since goes on
  local function press_perform(pane, x, y, z)
    if not whole_in(x, 1, PERFORM.keys.fill) or not whole_in(y, 1, NUM_VOICES) then return end
    local voice_idx, perform = y, PERFORM.keys
    if x == perform.order then return order_key(pane, x, voice_idx, z) end
    if x == perform.fill then return fill_key(pane, x, voice_idx, z) end
    if z ~= 1 then return end
    if x == perform.mute or x == perform.solo then
      toggle_param(param_of(voice_idx, x == perform.mute and "mute" or "solo"))
    elseif letter_of(x) then
      letter_key(pane, voice_idx, letter_of(x))
    elseif x == perform.latch then
      S.lib.loop_roll.press_latch(voice_idx)
    elseif roll_rate(x) then
      S.lib.loop_roll.roll(voice_idx, roll_rate(x), pane.still(x, voice_idx))
    elseif PERFORM.modes[x] then
      S.lib.lanes.choose_mode(voice_idx, PERFORM.modes[x])
    end
  end

  local function press(pane, x, y, z)
    if pane.side == PERFORM.side then return press_perform(pane, x, y, z) end
    press_voice_keys(pane, x, y, z)
  end

  -- A copy key's level: the copied (or marked) voice, the others while a
  -- copy exists, none
  local function copy_level(copy, voice_idx)
    if copy == nil then return levels.no_copy end
    return copy.voice == voice_idx and levels.copied or levels.target
  end

  -- FZ: frozen or not, blinking while the voice's freeze set waits for
  -- the quantizer (S.lib.freeze.waiting, #876, #1031)
  local function freeze_level(voice_idx)
    if S.lib.freeze.waiting(voice_idx) then return S.lib.grid_core.waiting_level() end
    return S.lib.freeze.is_frozen(voice_idx) and levels.freeze_on or levels.freeze_off
  end

  -- The perform side's lights ---------------------------------------------

  -- A letter: blinking while it waits (the core's blink, whose signature
  -- counts it while a pane shows this side), 15 playing, 4 used, 2 never
  local function letter_level(voice_idx, letter)
    local letters, perform = S.lib.pattern_letters, PERFORM.levels
    if letters.waiting(voice_idx) == letter then return S.lib.grid_core.waiting_level() end
    if letters.current(voice_idx) == letter then return perform.letter_playing end
    return letters.used(voice_idx, letter) and perform.letter_used or perform.letter_unused
  end

  -- OR: 10 while held (as OR, on this pane), 15 on, 4 an order held off, 2 none
  local function order_level(pane, voice_idx)
    local perform = PERFORM.levels
    if pane.pressed_as(PERFORM.keys.order, voice_idx, PERFORM.order_role) then return perform.order_held end
    local order, on = S.lib.pattern_letters.order(voice_idx)
    if on then return perform.order_on end
    return #order > 0 and perform.order_off or perform.order_none
  end

  -- LP: 15 latched, 6 a loop held and not latched, 10 armed, 2 off
  local function latch_level(voice_idx)
    local roll, perform = S.lib.loop_roll, PERFORM.levels
    if roll.latched(voice_idx) then return perform.latch_latched end
    if roll.loop(voice_idx) then return perform.latch_held end
    return roll.armed(voice_idx) and perform.latch_armed or perform.latch_off
  end

  -- A roll key: 15 while its rate rolls the voice, 4 else
  local function roll_level(voice_idx, rate)
    return S.lib.loop_roll.rolling(voice_idx) == rate and PERFORM.levels.roll_on or PERFORM.levels.roll_off
  end

  local function draw_perform(pane, led)
    local perform = PERFORM.keys
    local fill = S.lib.conditions.fill() and PERFORM.levels.fill_on or PERFORM.levels.fill_off
    for voice_idx = 1, NUM_VOICES do
      led(perform.mute, voice_idx, is_on(param_of(voice_idx, "mute")) and levels.on or levels.off)
      led(perform.solo, voice_idx, is_on(param_of(voice_idx, "solo")) and levels.on or levels.off)
      for n, letter in ipairs(all_letters()) do
        led(perform.first_letter + n - 1, voice_idx, letter_level(voice_idx, letter))
      end
      led(perform.order, voice_idx, order_level(pane, voice_idx))
      led(perform.latch, voice_idx, latch_level(voice_idx))
      for rate = 1, perform.rolls do led(perform.first_roll + rate - 1, voice_idx, roll_level(voice_idx, rate)) end
      for x, name in pairs(PERFORM.modes) do led(x, voice_idx, S.lib.grid_pages_patterns.mode_level(voice_idx, name)) end
      led(perform.fill, voice_idx, fill)
    end
  end

  local function redraw(pane, led)
    if pane.side == PERFORM.side then return draw_perform(pane, led) end
    local state = pane.state()
    for voice_idx = 1, NUM_VOICES do
      led(keys.mute, voice_idx, is_on(param_of(voice_idx, "mute")) and levels.on or levels.off)
      led(keys.solo, voice_idx, is_on(param_of(voice_idx, "solo")) and levels.on or levels.off)
      led(keys.lock, voice_idx, S.lib.grid_core.lock_level(voice_idx))
      led(keys.freeze, voice_idx, freeze_level(voice_idx))
      for _, x in ipairs(HOLD_KEYS) do
        led(x, voice_idx, pane.hold_pending(x, voice_idx) and levels.pending or levels.idle)
      end
      led(keys.pattern_copy, voice_idx, copy_level(state.patterns, voice_idx))
      led(keys.voice_copy, voice_idx, copy_level(state.sound, voice_idx))
    end
  end

  -- x 9-16 of each line on side 1: the voice's level, for the params that
  -- exist; side 2 has none
  local function faders(pane)
    local found = {}
    if pane.side == PERFORM.side then return found end
    for voice_idx = 1, NUM_VOICES do
      local id = param_of(voice_idx, "amp")
      if exists(id) then
        found[#found + 1] = {line = voice_idx, first = VOICES_PAGE.level_first, keys = VOICES_PAGE.level_keys, id = id}
      end
    end
    return found
  end

  -- Side 2's: per voice what its keys show but a wait (the blink's) and a
  -- held OR (its key's repaint): the letter played and those used, the
  -- order and whether it is on, the latch, the roll and the mode; and
  -- fill. A scene recall's letters, a mode set from SEQ or a loop a length
  -- cut repaint through it at the drift tick at the latest
  local function perform_signature()
    local letters = S.lib.pattern_letters
    local parts = {tostring(S.lib.conditions.fill())}
    for voice_idx = 1, NUM_VOICES do
      local used = {}
      for _, letter in ipairs(all_letters()) do used[#used + 1] = letters.used(voice_idx, letter) and letter or "-" end
      local order, on = letters.order(voice_idx)
      parts[#parts + 1] = table.concat({letters.current(voice_idx), table.concat(used), table.concat(order),
        tostring(on), latch_level(voice_idx), tostring(S.lib.loop_roll.rolling(voice_idx)),
        tostring(S.lib.sequencer.step_mode(voice_idx))}, ":")
    end
    return table.concat(parts, ",")
  end

  -- What the follow compares beside the level lines: each voice's lock
  -- (a scene's lock entry sets S.locked with no redraw of its own until
  -- the recall ends) and the two copies. Mute, solo and freeze have no
  -- term: their params' actions always redraw the grids
  local function signature(pane)
    if pane.side == PERFORM.side then return perform_signature() end
    local parts = {}
    for voice_idx = 1, NUM_VOICES do parts[#parts + 1] = tostring(S.locked[voice_idx] == true) end
    local state = pane.state()
    parts[#parts + 1] = state.patterns and state.patterns.voice or "-"
    parts[#parts + 1] = state.sound and state.sound.voice or "-"
    return table.concat(parts, ",")
  end

  M.record = {
    name = "voices",
    index = S.constants.GRID_PAGES.voices,
    sides = PERFORM.side,
    press = press,
    redraw = redraw,
    faders = faders,
    signature = signature,
  }
  S.register_grid_page(M.record)

  return M
end

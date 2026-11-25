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
-- half-second hold (a recorder's clear waits it too)

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

  local function press(pane, x, y, z)
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

  local function redraw(pane, led)
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

  -- x 9-16 of each line: the voice's level, for the params that exist
  local function faders()
    local found = {}
    for voice_idx = 1, NUM_VOICES do
      local id = param_of(voice_idx, "amp")
      if exists(id) then
        found[#found + 1] = {line = voice_idx, first = VOICES_PAGE.level_first, keys = VOICES_PAGE.level_keys, id = id}
      end
    end
    return found
  end

  -- What the follow compares beside the level lines: each voice's lock
  -- (a scene's lock entry sets S.locked with no redraw of its own until
  -- the recall ends) and the two copies. Mute, solo and freeze have no
  -- term: their params' actions always redraw the grids
  local function signature(pane)
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
    press = press,
    redraw = redraw,
    faders = faders,
    signature = signature,
  }
  S.register_grid_page(M.record)

  return M
end

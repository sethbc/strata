-- lib/grid/pages/sources.lua
-- Grid page 4, sources (3.8, design §10.6): line v is voice v's source,
-- one lit key a line. x 1-7 the voices: another voice's column reads that
-- voice's output; the voice's own column is its synth, and pressed again
-- on the synth its own output (which blinks). x 8 the input, pressed
-- again its channel (stereo, left, right); x 9-16 the eight slots. Every
-- press sets v<v>_source (or v<v>_input_channel) through its param, whose
-- action does the engine's switch and redraws the grids. Written in pane
-- coordinates (lib/grid/pane.lua), so it is the same on every layout; on
-- a 64 the left half is the voices and the input, the right the slots

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local SOURCE_SYNTH = S.constants.SOURCE_SYNTH
  local SOURCE_INPUT = S.constants.SOURCE_INPUT
  local SOURCE_VOICE_FIRST = S.constants.SOURCE_VOICE_FIRST

  -- The columns (pane coordinates: voice j at x j, then the input, then
  -- slot n at slot_column + n), the levels, the blink of a voice that
  -- reads its own output (blink_seconds each of on and off), and the slow
  -- blink of a slot whose remembered file was not found on start
  -- (slot_missing and slot_missing_off for missing_blink_seconds each,
  -- #1026)
  local SOURCES_PAGE = {
    input_column = NUM_VOICES + 1,
    slot_column = NUM_VOICES + 1,
    blink_seconds = 0.5,
    missing_blink_seconds = 1,
    levels = {selected = 15, blink_off = 6, other = 4, voice_running = 4, voice_stopped = 2,
      slot_free = 2, slot_audio = 4, slot_missing = 4, slot_missing_off = 0, channels = {15, 11, 7}},
  }
  M.SOURCES_PAGE = SOURCES_PAGE

  local levels = SOURCES_PAGE.levels

  local function whole_in(n, low, high)
    return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
  end

  local function source_param(voice_idx) return "v" .. voice_idx .. "_source" end
  local function channel_param(voice_idx) return "v" .. voice_idx .. "_input_channel" end

  local function source_of(voice_idx) return S.voices[voice_idx].source end

  -- The voice's own output as its source
  local function own_source(voice_idx) return SOURCE_VOICE_FIRST + voice_idx - 1 end

  -- The input channel (1 stereo, 2 left, 3 right), or nil while the param
  -- is not there
  local function channel_of(voice_idx)
    local id = channel_param(voice_idx)
    if params.lookup[id] == nil then return nil end
    return params:get(id)
  end

  local function channel_count(voice_idx)
    return #params:lookup_param(channel_param(voice_idx)).options
  end

  -- The slot of column x, or nil
  local function slot_of(x)
    local slot = x - SOURCES_PAGE.slot_column
    if slot >= 1 and slot <= NUM_BUFFERS then return slot end
    return nil
  end

  -- The blink's phase: 0 lit, 1 dim, each blink_seconds
  local function blink_phase()
    return math.floor(util.time() / SOURCES_PAGE.blink_seconds) % 2
  end

  -- The missing blink's phase: 0 lit, 1 dark, each missing_blink_seconds
  local function missing_phase()
    return math.floor(util.time() / SOURCES_PAGE.missing_blink_seconds) % 2
  end

  local function is_missing(slot) return S.lib.buffers.status(slot) == "missing" end

  local function any_missing()
    for slot = 1, NUM_BUFFERS do
      if is_missing(slot) then return true end
    end
    return false
  end

  local function any_reads_itself()
    for voice_idx = 1, NUM_VOICES do
      if source_of(voice_idx) == own_source(voice_idx) then return true end
    end
    return false
  end

  local function press(_, x, y, z)
    if z ~= 1 or not whole_in(x, 1, SOURCES_PAGE.slot_column + NUM_BUFFERS) or not whole_in(y, 1, NUM_VOICES) then
      return
    end
    local core = S.lib.grid_core
    local voice_idx, current = y, source_of(y)
    if x == voice_idx then
      -- the synth, or on the synth the voice's own output
      core.source_key(voice_idx, current == SOURCE_SYNTH and own_source(voice_idx) or SOURCE_SYNTH)
    elseif x <= NUM_VOICES then
      core.source_key(voice_idx, SOURCE_VOICE_FIRST + x - 1)
    elseif x == SOURCES_PAGE.input_column then
      if current ~= SOURCE_INPUT then
        core.source_key(voice_idx, SOURCE_INPUT)  -- the channel kept
      elseif channel_of(voice_idx) then
        params:set(channel_param(voice_idx), channel_of(voice_idx) % channel_count(voice_idx) + 1)
      end
    elseif slot_of(x) then
      core.source_key(voice_idx, SOURCE_SYNTH + slot_of(x))
    end
  end

  local function voice_key_level(voice_idx, x, current)
    if x == voice_idx then
      if current == SOURCE_SYNTH then return levels.selected end
      if current == own_source(voice_idx) then
        return blink_phase() == 0 and levels.selected or levels.blink_off
      end
      return levels.other
    end
    if current == SOURCE_VOICE_FIRST + x - 1 then return levels.selected end
    return S.voices[x].active and levels.voice_running or levels.voice_stopped
  end

  local function input_level(voice_idx, current)
    if current ~= SOURCE_INPUT then return levels.other end
    return levels.channels[channel_of(voice_idx)] or levels.selected
  end

  local function slot_level(slot, current)
    if current == SOURCE_SYNTH + slot then return levels.selected end
    if is_missing(slot) then return missing_phase() == 0 and levels.slot_missing or levels.slot_missing_off end
    return S.lib.buffers.is_free(slot) and levels.slot_free or levels.slot_audio
  end

  local function redraw(_, led)
    for voice_idx = 1, NUM_VOICES do
      local current = source_of(voice_idx)
      for x = 1, NUM_VOICES do led(x, voice_idx, voice_key_level(voice_idx, x, current)) end
      led(SOURCES_PAGE.input_column, voice_idx, input_level(voice_idx, current))
      for slot = 1, NUM_BUFFERS do
        led(SOURCES_PAGE.slot_column + slot, voice_idx, slot_level(slot, current))
      end
    end
  end

  -- What the drift tick's follow compares: the blink's phase while a voice
  -- reads its own output and the missing blink's while a slot is missing
  -- (so each costs nothing while nothing shows it), and each voice's input
  -- channel (its param redraws no grid). The sources, the slots and the
  -- voices' running redraw the grids themselves
  local function signature()
    local parts = {any_reads_itself() and blink_phase() or "-", any_missing() and missing_phase() or "-"}
    for voice_idx = 1, NUM_VOICES do parts[#parts + 1] = tostring(channel_of(voice_idx)) end
    return table.concat(parts, ",")
  end

  M.record = {
    name = "sources",
    index = S.constants.GRID_PAGES.sources,
    press = press,
    redraw = redraw,
    signature = signature,
  }
  S.register_grid_page(M.record)

  return M
end

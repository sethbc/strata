-- lib/grid/faders.lua
-- The grid faders, which the 256 (its parameter page and FX faders), the
-- 16x8 and the 8x16 (their faders pages) draw and set alike: which params a
-- voice's fader pages show, the column <-> value mapping (following each
-- param's warp, with a zero column for ranges that span 0), the fader rows'
-- LEDs, the fader page keys' level and the drift tick's redraw when a shown
-- fader moved (follow_faders). The functions stay global.

return function(S)
  local M = {}
  local NUM_MOD_SLOTS = S.constants.NUM_MOD_SLOTS
  local GRID_LAYOUT = S.lib.grid_core.GRID_LAYOUT

  -- A buffer-sourced voice's first faders: its buffer params, then its level
  -- and pan (voice_level_fader_keys; the other synthesis params do nothing
  -- while the synth is off)
  local BUFFER_FADER_KEYS = {"buf_pos", "buf_rate", "buf_scan"}
  -- The six grain params (envelope shape and grain mode are option params,
  -- shown as index faders)
  local GRAIN_FADER_KEYS = {"grain_size", "grain_density", "grain_pitch", "grain_spread", "grain_env", "grain_mode"}

  local function append_fader_ids(ids, prefix, keys)
    for _, key in ipairs(keys) do
      table.insert(ids, prefix .. key)
    end
  end

  -- The synthesis params every source applies: level, and pan for the voices
  -- that have it (sub has none). The engine pans buffer and input grains too.
  function voice_level_fader_keys(voice_idx)
    local keys = {"amp"}
    if S.voices[voice_idx].params.pan ~= nil then table.insert(keys, "pan") end
    return keys
  end

  -- Ordered param IDs for a voice's fader pages (on every layout): the voice's synthesis
  -- params (param_order), or BUFFER_FADER_KEYS and the level and pan for a
  -- buffer source, then the grain params, then the nine crossmod slot values
  -- (source, amp mod, freq mod for each slot). An input source has no buffer
  -- params, and of its synth params only the level and pan do anything: its
  -- faders start with the grain params, then the level and pan.
  function fader_param_ids(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    local ids = {}
    if voice_uses_synth(voice_idx) then
      append_fader_ids(ids, prefix, S.voices[voice_idx].param_order)
      append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
    elseif voice_uses_buffer(voice_idx) then
      append_fader_ids(ids, prefix, BUFFER_FADER_KEYS)
      append_fader_ids(ids, prefix, voice_level_fader_keys(voice_idx))
      append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
    else
      append_fader_ids(ids, prefix, GRAIN_FADER_KEYS)
      append_fader_ids(ids, prefix, voice_level_fader_keys(voice_idx))
    end
    for slot = 1, NUM_MOD_SLOTS do
      table.insert(ids, prefix .. "mod_source_" .. slot)
      table.insert(ids, prefix .. "mod_amp_amt_" .. slot)
      table.insert(ids, prefix .. "mod_freq_amt_" .. slot)
    end
    return ids
  end

  function fader_page_count(voice_idx)
    return math.ceil(#fader_param_ids(voice_idx) / GRID_LAYOUT.fader_rows)
  end

  -- A fader whose range spans 0 (pan, buffer scan, the crossmod amounts) has
  -- a zero column: the column nearest 0's place on the range, never an end
  -- one. 16 columns have no center, so a plain sweep would give +/-0.07 for
  -- pan there and never 0. nil for any other range.
  function fader_zero_column(param_id)
    local minval, maxval = param_range(param_id)
    if not (minval < 0 and maxval > 0) then return nil end
    local last_column = GRID_LAYOUT.fader_width
    local column = util.round(param_value_fraction(param_id, 0) * (last_column - 1) + 1)
    return util.clamp(column, 2, last_column - 1)
  end

  -- The fraction of its range (in the warp's terms) column x (1-16) sets.
  -- Columns sweep the range evenly; a fader with a zero column sweeps each
  -- side of 0 evenly over its own columns instead, so column 1 is still the
  -- minimum, the zero column 0 and column 16 the maximum.
  function fader_column_fraction(param_id, x)
    local last_column = GRID_LAYOUT.fader_width
    local zero_column = fader_zero_column(param_id)
    if not zero_column then return (x - 1) / (last_column - 1) end
    local zero_fraction = param_value_fraction(param_id, 0)
    if x <= zero_column then
      return util.linlin(1, zero_column, 0, zero_fraction, x)
    end
    return util.linlin(zero_column, last_column, zero_fraction, 1, x)
  end

  -- Grid column x (1-16) sets a param across its range. Control params follow
  -- their controlspec warp; number params (mod sources) and option params
  -- (grain envelope, as an option index) map linearly to integers. A zero
  -- column sets exactly 0.
  function set_param_from_column(param_id, x)
    local spec = params:lookup_param(param_id).controlspec
    local value = 0
    if x ~= fader_zero_column(param_id) then
      local fraction = fader_column_fraction(param_id, x)
      if spec then
        value = spec:map(fraction)
      else
        local minval, maxval = param_range(param_id)
        value = util.round(util.linlin(0, 1, minval, maxval, fraction))
      end
    end
    params:set(param_id, value)
  end

  -- Column x on one of the parameter page's faders
  function set_fader_param(voice_idx, fader_index, x)
    local param_id = fader_param_ids(voice_idx)[fader_index]
    if not param_id then return end
    set_param_from_column(param_id, x)
  end

  -- Grid column (1-16) that shows a fader param's current value: the inverse
  -- of fader_column_fraction, so 0 shows at a zero column
  function fader_position(param_id)
    local last_column = GRID_LAYOUT.fader_width
    local fraction = param_fraction(param_id)
    local zero_column = fader_zero_column(param_id)
    if not zero_column then
      return util.round(fraction * (last_column - 1) + 1)
    end
    local zero_fraction = param_value_fraction(param_id, 0)
    if fraction <= zero_fraction then
      return util.round(util.linlin(0, zero_fraction, 1, zero_column, fraction))
    end
    return util.round(util.linlin(zero_fraction, 1, zero_column, last_column, fraction))
  end

  -- One fader on row y: a bar (brightness 8) up to the param's current value,
  -- with the value's own column at 15
  function grid_redraw_fader_row(grid_device, y, param_id)
    local position = fader_position(param_id)
    for x = 1, position - 1 do
      grid_device:led(x, y, 8)
    end
    grid_device:led(position, y, 15)
  end

  -- What a faders page shows of the faders, as one string: the grid voice,
  -- its fader page, its page count and the shown faders' columns. A param
  -- set anywhere (the screen, the arc, a MIDI map, PARAMETERS, the drift)
  -- reaches the grid through follow_faders, which the drift tick runs (#324)
  local shown_faders  -- the string as of the last look (nil: no grid on page 2)

  function M.faders_signature()
    local voice_idx = S.grid_voice_select
    local ids = fader_param_ids(voice_idx)
    local parts = {voice_idx, S.param_page, fader_page_count(voice_idx)}
    for row = 1, GRID_LAYOUT.fader_rows do
      local param_id = ids[(S.param_page - 1) * GRID_LAYOUT.fader_rows + row]
      parts[#parts + 1] = param_id and fader_position(param_id) or 0
    end
    return table.concat(parts, ",")
  end

  -- While a grid shows the faders page, redraw the grids when what the
  -- faders show changed since the last look (the first look draws too), so
  -- idle ticks repaint nothing
  function M.follow_faders()
    if not S.lib.grid_core.any_page(S.constants.GRID_PAGES.faders) then
      shown_faders = nil
      return
    end
    local signature = M.faders_signature()
    if signature ~= shown_faders then grid_redraw() end
    shown_faders = signature
  end

  -- A fader page's key (the 256's row 13, the 16x8's row 5, the 8x16's
  -- column 5): the page shown picked, the others not (the core's levels)
  function M.fader_page_level(page)
    local levels = S.lib.grid_core.LEVELS
    return page == S.param_page and levels.picked or levels.unpicked
  end

  -- Fader rows 9-12 for the selected voice's fader page. Row 13 shows the
  -- fader pages (fader_page_level).
  function grid_redraw_faders(grid_device)
    local ids = fader_param_ids(S.grid_voice_select)
    for row = 1, GRID_LAYOUT.fader_rows do
      local param_id = ids[(S.param_page - 1) * GRID_LAYOUT.fader_rows + row]
      if param_id then
        grid_redraw_fader_row(grid_device, GRID_LAYOUT.fader_first_row + row - 1, param_id)
      end
    end
    for page = 1, fader_page_count(S.grid_voice_select) do
      grid_device:led(page, GRID_LAYOUT.param_page_row, M.fader_page_level(page))
    end
  end

  return M
end

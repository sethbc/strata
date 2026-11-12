-- lib/grid/faders.lua
-- The grid faders, which the 256 (its parameter page and FX faders), the
-- 16x8 and the 8x16 (their faders pages) draw and set alike: which params a
-- voice's fader pages show, the column <-> value mapping (following each
-- param's warp, with a zero column for ranges that span 0), the fader rows'
-- LEDs, the fader page keys' level and the drift tick's redraw when a shown
-- fader moved (follow_faders, which 3.4 extends to the macro faders and the
-- morph), and 3.4's shown macro bank, the 16x8's and 8x16's macro fader
-- page key and set_param_fraction (the 256's morph pad). The functions that
-- were global stay global.

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
  -- column sets exactly 0. Then the touch hooks run, as "grid" (3.4)
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
    S.lib.ui_detent.run_touch_hooks(param_id, "grid")
  end

  -- 3.4 (3a): set a control param at a fraction (0-1, clamped) of its
  -- range, in its warp's terms (the 256's morph pad); another param maps
  -- linearly to its whole values. Then the touch hooks run, as "grid", so
  -- a gesture recorder records it
  function M.set_param_fraction(param_id, fraction)
    local spec = params:lookup_param(param_id).controlspec
    fraction = util.clamp(fraction, 0, 1)
    if spec then
      params:set(param_id, spec:map(fraction))
    else
      local minval, maxval = param_range(param_id)
      params:set(param_id, util.round(util.linlin(0, 1, minval, maxval, fraction)))
    end
    S.lib.ui_detent.run_touch_hooks(param_id, "grid")
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

  -- 3.4: the shown macro bank's four param ids (macro_<m>, through
  -- S.lib.macros.bank_macros), which the 256's page 1 and the 16x8's and
  -- 8x16's faders page on a bank show
  function M.shown_macro_ids()
    local ids = {}
    for index, m in ipairs(S.lib.macros.bank_macros(S.lib.macros.bank())) do ids[index] = "macro_" .. m end
    return ids
  end

  -- What the macro faders and the morph show (3.4), as one string: the
  -- shown bank, its macros' columns, the morph's column, its scenes A to D
  -- and its position (x and y, which the 256's pad shows finer than the
  -- fader's columns). The morph and its scenes are set on MOD, the arc, a
  -- MIDI map and in PARAMETERS too, and none of their actions redraws the
  -- grids
  function M.modulation_signature()
    local parts = {S.lib.macros.bank()}
    for _, param_id in ipairs(M.shown_macro_ids()) do parts[#parts + 1] = fader_position(param_id) end
    parts[#parts + 1] = fader_position("morph")
    for _, param_id in ipairs({"morph_a", "morph_b", "morph_c", "morph_d", "morph", "morph_y"}) do
      parts[#parts + 1] = params:get(param_id)
    end
    return table.concat(parts, ",")
  end

  -- While a grid shows the faders page, or the macro faders or the morph
  -- (S.lib.grid_core.any_modulation_shown), redraw the grids when what
  -- they show changed since the last look (the first look draws too), so
  -- idle ticks repaint nothing
  function M.follow_faders()
    local signature
    if S.lib.grid_core.any_page(S.constants.GRID_PAGES.faders) then signature = M.faders_signature() end
    if S.lib.grid_core.any_modulation_shown() then
      signature = (signature or "") .. "|" .. M.modulation_signature()
    end
    if signature == nil then
      shown_faders = nil
      return
    end
    if signature ~= shown_faders then grid_redraw() end
    shown_faders = signature
  end

  -- The 16x8's and 8x16's macro fader page key (3.4, design §4.6, §11;
  -- ruling 81): from the voice faders a press shows the bank every surface
  -- shows now (S.lib.macros.bank()), changing nothing elsewhere; each
  -- further press shows the next bank (after the last comes bank 1,
  -- through S.lib.macros.set_bank, which flashes and redraws every grid
  -- and the arc), and the press after the fourth bank shown since entering
  -- goes back to the voice faders (the bank stays). Per port:
  -- port_state(port).macro_faders counts the banks the key showed since
  -- entering (nil on the voice faders), forgotten with its grid; the bank
  -- itself is the one every surface shows, so a bank set elsewhere shows
  -- at once. Its LED: 4 on the voice faders, 6, 9, 12 and 15 on banks 1-4
  local MACRO_PAGE = {levels = {4, 6, 9, 12, 15}}

  -- Whether the port's faders page shows the shown bank's macros
  function M.shows_macros(port)
    return S.lib.grid_core.port_state(port).macro_faders ~= nil
  end

  function M.macro_page_key(port)
    local state = S.lib.grid_core.port_state(port)
    local banks = S.lib.macros.MACROS.banks
    if state.macro_faders == nil then
      state.macro_faders = 1
    elseif state.macro_faders < banks then
      state.macro_faders = state.macro_faders + 1
      S.lib.macros.set_bank(S.lib.macros.bank() % banks + 1)
    else
      state.macro_faders = nil
    end
    grid_redraw()
  end

  -- A fader page key or a voice select key pressed on a 16x8's or 8x16's
  -- faders page (ruling 82): the port leaves the macros, so its faders
  -- show the page of the voice the key picked. Other grids keep theirs
  function M.leave_macros(port)
    S.lib.grid_core.port_state(port).macro_faders = nil
    grid_redraw()
  end

  function M.macro_page_level(port)
    if not M.shows_macros(port) then return MACRO_PAGE.levels[1] end
    return MACRO_PAGE.levels[S.lib.macros.bank() + 1] or MACRO_PAGE.levels[1]
  end

  -- The four param ids a 16x8's or 8x16's faders page shows on the port,
  -- fader 1 first (nil where the voice has no fader there): the shown
  -- bank's macros while the port shows a bank, else the grid voice's fader
  -- page S.param_page. Its keys and its redraw both read it
  function M.shown_fader_ids(port)
    if M.shows_macros(port) then return M.shown_macro_ids() end
    local ids, shown = fader_param_ids(S.grid_voice_select), {}
    for row = 1, GRID_LAYOUT.fader_rows do shown[row] = ids[(S.param_page - 1) * GRID_LAYOUT.fader_rows + row] end
    return shown
  end

  -- The 16x8's and 8x16's layout records' shows_modulation: their scenes
  -- page (the morph) and their faders page while it shows a bank
  function M.shows_modulation(port)
    local page = S.lib.grid_core.page(port)
    local pages = S.constants.GRID_PAGES
    return page == pages.scenes or (page == pages.faders and M.shows_macros(port))
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

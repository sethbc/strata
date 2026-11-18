-- lib/grid/faders.lua
-- The grid faders every page sets and draws alike: which params a voice's
-- fader pages show, the key <-> value mapping along a fader of 16 keys,
-- or of 8 on a 64's half (each function's width; following each param's
-- warp, with a zero key for ranges that span 0), the fader page keys'
-- level, the shown macro bank, and the drift tick's redraw when a shown
-- fader line or a page's signature moved (follow_faders, through
-- S.lib.grid_pane.signature). The pane engine (lib/grid/pane.lua) owns the
-- keys of a page's fader lines and draws them. The functions that were
-- global stay global.

return function(S)
  local M = {}
  local GRID_LAYOUT = S.lib.grid_core.GRID_LAYOUT

  -- The synthesis params every source applies: level, and pan for the voices
  -- that have it (sub has none). The engine pans buffer and input grains
  -- too. The grain record's fader groups (lib/voices.lua) read it
  function voice_level_fader_keys(voice_idx)
    local keys = {"amp"}
    if S.lib.voices.is_synth_key(voice_idx, "pan") then table.insert(keys, "pan") end
    return keys
  end

  -- Ordered param IDs for a voice's fader pages (on every layout): every
  -- voice-param record's fader groups (S.registry.voice_params' fader, the
  -- groundwork before 3.8) whose when holds for the voice (all without
  -- one), sorted by rank (default 0) and, within a rank, in registration
  -- order. The built-in records' groups (rank 0) give 3.7's faders: the
  -- synthesis params (param_order) on a synth source, a buffer source's
  -- buffer params, level and pan, the six grain params (envelope and mode
  -- are index faders), an input source's level and pan, then the nine
  -- crossmod slot values; then the voice filter and sends (rank 1), a
  -- buffer voice's loop (2), the jitters (3), attack and release (4)
  function fader_param_ids(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    local groups = {}
    for _, record in ipairs(S.registry.voice_params) do
      for _, group in ipairs(record.fader or {}) do
        if not group.when or group.when(voice_idx) then groups[#groups + 1] = group end
      end
    end
    -- a stable sort: insertion, moving a group only past higher ranks
    for index = 2, #groups do
      local group, position = groups[index], index
      while position > 1 and (groups[position - 1].rank or 0) > (group.rank or 0) do
        groups[position] = groups[position - 1]
        position = position - 1
      end
      groups[position] = group
    end
    local ids = {}
    for _, group in ipairs(groups) do
      for _, key in ipairs(S.lib.params_setup.group_keys(group, voice_idx)) do ids[#ids + 1] = prefix .. key end
    end
    return ids
  end

  function fader_page_count(voice_idx)
    return math.ceil(#fader_param_ids(voice_idx) / GRID_LAYOUT.fader_rows)
  end

  -- A fader of `width` keys (GRID_LAYOUT.fader_width, 16, when not given;
  -- 8 on a 64's half)
  local function keys_of(width) return width or GRID_LAYOUT.fader_width end

  -- A fader whose range spans 0 (pan, buffer scan, the crossmod amounts) has
  -- a zero key: the key nearest 0's place on the range, never an end one
  -- (2..width - 1). 16 keys have no center, so a plain sweep would give
  -- +/-0.07 for pan there and never 0. nil for any other range.
  function fader_zero_column(param_id, width)
    local minval, maxval = param_range(param_id)
    if not (minval < 0 and maxval > 0) then return nil end
    local last_column = keys_of(width)
    local column = util.round(param_value_fraction(param_id, 0) * (last_column - 1) + 1)
    return util.clamp(column, 2, last_column - 1)
  end

  -- The fraction of its range (in the warp's terms) key x (1..width) sets.
  -- Keys sweep the range evenly; a fader with a zero key sweeps each side
  -- of 0 evenly over its own keys instead, so key 1 is still the minimum,
  -- the zero key 0 and the last key the maximum.
  function fader_column_fraction(param_id, x, width)
    local last_column = keys_of(width)
    local zero_column = fader_zero_column(param_id, last_column)
    if not zero_column then return (x - 1) / (last_column - 1) end
    local zero_fraction = param_value_fraction(param_id, 0)
    if x <= zero_column then
      return util.linlin(1, zero_column, 0, zero_fraction, x)
    end
    return util.linlin(zero_column, last_column, zero_fraction, 1, x)
  end

  -- Key x (1..width) of a fader sets a param across its range. Control
  -- params follow their controlspec warp; number params (mod sources) and
  -- option params (an option index) map linearly to integers. A zero key
  -- sets exactly 0. Then the touch hooks run, as "grid" (3.4)
  function set_param_from_column(param_id, x, width)
    local spec = params:lookup_param(param_id).controlspec
    local value = 0
    if x ~= fader_zero_column(param_id, width) then
      local fraction = fader_column_fraction(param_id, x, width)
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

  -- 3.7 (ruling 34): the param an FX fader sets and shows: its own, but
  -- the delay's time fader picks the division while the delay is synced
  -- (S.lib.delay_sync), its twelve values along the fader as an option
  -- fader's, as FX's time row and arc ring 3 do
  local FX_SYNCED_FADERS = {delay_time = "delay_division"}
  function M.fx_fader_id(param_id)
    local synced = FX_SYNCED_FADERS[param_id]
    if synced and S.lib.delay_sync.playing() then return synced end
    return param_id
  end

  -- The key (1..width) that shows a fader param's current value: the
  -- inverse of fader_column_fraction, so 0 shows at a zero key
  function fader_position(param_id, width)
    local last_column = keys_of(width)
    local fraction = param_fraction(param_id)
    local zero_column = fader_zero_column(param_id, last_column)
    if not zero_column then
      return util.round(fraction * (last_column - 1) + 1)
    end
    local zero_fraction = param_value_fraction(param_id, 0)
    if fraction <= zero_fraction then
      return util.round(util.linlin(0, zero_fraction, 1, zero_column, fraction))
    end
    return util.round(util.linlin(zero_fraction, 1, zero_column, last_column, fraction))
  end

  -- What a voice's fader page shows, as one string: the grid voice, its
  -- fader page, its page count and the shown faders' keys
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
  -- S.lib.macros.bank_macros)
  function M.shown_macro_ids()
    local ids = {}
    for index, m in ipairs(S.lib.macros.bank_macros(S.lib.macros.bank())) do ids[index] = "macro_" .. m end
    return ids
  end

  -- What the macro faders and the morph show (3.4), as one string: the
  -- shown bank, its macros' keys, the morph's key, its scenes A to D and
  -- its position (x and y). The morph and its scenes are set on MOD, the
  -- arc, a MIDI map and in PARAMETERS too, and none of their actions
  -- redraws the grids
  function M.modulation_signature()
    local parts = {S.lib.macros.bank()}
    for _, param_id in ipairs(M.shown_macro_ids()) do parts[#parts + 1] = fader_position(param_id) end
    parts[#parts + 1] = fader_position("morph")
    for _, param_id in ipairs({"morph_a", "morph_b", "morph_c", "morph_d", "morph", "morph_y"}) do
      parts[#parts + 1] = params:get(param_id)
    end
    return table.concat(parts, ",")
  end

  -- What the grids show of params set anywhere (the screen, the arc, a
  -- MIDI map, PARAMETERS, the drift; #324), as of the last look: nil while
  -- no pane shows a fader line or a page with a signature
  local shown_faders

  -- The drift tick (lib/mutation.lua, 10 Hz) calls it: while a pane shows
  -- fader lines or a page with a signature (S.lib.grid_pane.signature),
  -- redraw the grids when what they show changed since the last look (the
  -- first look draws too), so idle ticks repaint nothing
  function M.follow_faders()
    local signature = S.lib.grid_pane.signature()
    if signature == nil then
      shown_faders = nil
      return
    end
    if signature ~= shown_faders then grid_redraw() end
    shown_faders = signature
  end

  -- A fader page's key (the faders page's): the page shown picked, the
  -- others not (the core's levels)
  function M.fader_page_level(page)
    local levels = S.lib.grid_core.LEVELS
    return page == S.param_page and levels.picked or levels.unpicked
  end

  return M
end

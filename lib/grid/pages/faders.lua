-- lib/grid/pages/faders.lua
-- Grid page 2, faders (3.8, design §10.4, ruling 31): lines 1-4 four
-- faders of the grid voice's fader page (fader_param_ids) or, while the
-- port shows a macro bank, that bank's four macros; line 5 the fader page
-- keys (x 1-10) and the macro banks (x 12-15); line 6 the grid voice's
-- type, a key a registered type in type order, set at once; line 7 the
-- voice picker. Written in pane coordinates (lib/grid/pane.lua), so it is
-- the same on every layout; its state (whether the port shows the macros)
-- is pane.state()'s

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local LEVELS = S.constants.GRID_LEVELS
  local FADER_ROWS = S.lib.grid_core.GRID_LAYOUT.fader_rows

  -- The lines (pane coordinates), line 5's keys and the levels. A fader
  -- line is the pane's whole line (eight keys on a 64's half)
  local FADERS_PAGE = {
    lines = {pages = 5, types = 6, voices = 7},
    page_keys = 10,   -- line 5's x 1-10: the fader pages (ruling 31)
    first_bank = 12,  -- line 5's x 12 on: the macro banks, bank x - 11
    line_keys = S.lib.grid_pane.LINE_KEYS,
    levels = {picked = LEVELS.picked, unpicked = LEVELS.unpicked, bank_targets = 6, bank_empty = 2, dark = 0},
  }
  M.FADERS_PAGE = FADERS_PAGE

  local lines, levels = FADERS_PAGE.lines, FADERS_PAGE.levels

  local function exists(param_id) return type(param_id) == "string" and params.lookup[param_id] ~= nil end

  -- Whether the port shows the bank's macros on lines 1-4
  local function shows_macros(pane) return pane.state().macros == true end

  local function bank_count() return S.lib.macros.MACROS.banks end

  -- Line 5's bank of key x, or nil
  local function bank_of(x)
    local bank = x - FADERS_PAGE.first_bank + 1
    if bank >= 1 and bank <= bank_count() then return bank end
    return nil
  end

  -- The ids lines 1-4 show: the shown bank's macros, or the grid voice's
  -- fader page's (a line may have none)
  local function line_ids(pane)
    if shows_macros(pane) then return S.lib.grid_faders.shown_macro_ids() end
    local ids = fader_param_ids(S.grid_voice_select)
    local shown = {}
    for line = 1, FADER_ROWS do shown[line] = ids[(S.param_page - 1) * FADER_ROWS + line] end
    return shown
  end

  -- Lines 1-4 for the params that exist: a line without one is dark and
  -- dead (the engine's draw path reads fader_position outside its
  -- containment, so no id that is no param is ever listed)
  local function faders(pane)
    local found = {}
    local ids = line_ids(pane)
    for line = 1, FADER_ROWS do
      if exists(ids[line]) then
        found[#found + 1] = {line = line, first = 1, keys = FADERS_PAGE.line_keys, id = ids[line]}
      end
    end
    return found
  end

  local function page_key(pane, x)
    if x > fader_page_count(S.grid_voice_select) then return end
    pane.state().macros = nil
    S.param_page = x
  end

  local function bank_key(pane, x)
    if S.lib.macros.set_bank(bank_of(x)) then pane.state().macros = true end
  end

  -- A type key: the x-th registered type, at once (S.lib.types.set
  -- cancels the voice's pending VOICE choice, ruling 63; the v<i>_type
  -- action clamps S.param_page to the new type's pages)
  local function type_key(x)
    local record = S.lib.types.list()[x]
    if record == nil then return end
    S.lib.types.set(S.grid_voice_select, record.key)
  end

  local function press(pane, x, y, z)
    if z ~= 1 or type(x) ~= "number" or x < 1 or x > FADERS_PAGE.line_keys then return end
    if y == lines.pages then
      if x <= FADERS_PAGE.page_keys then
        page_key(pane, x)
      elseif bank_of(x) then
        bank_key(pane, x)
      end
    elseif y == lines.types then
      type_key(x)
    elseif y == lines.voices and x <= NUM_VOICES then
      pane.state().macros = nil
      select_grid_voice(x)
    end
  end

  local function redraw(pane, led)
    local voice_idx = S.grid_voice_select
    local macros = shows_macros(pane)
    local count = fader_page_count(voice_idx)
    for x = 1, FADERS_PAGE.page_keys do
      local level = levels.dark
      if x <= count then level = macros and levels.unpicked or S.lib.grid_faders.fader_page_level(x) end
      led(x, lines.pages, level)
    end
    local shown_bank = S.lib.macros.bank()
    for bank = 1, bank_count() do
      local level = S.lib.macros.bank_has_targets(bank) and levels.bank_targets or levels.bank_empty
      if macros and bank == shown_bank then level = levels.picked end
      led(FADERS_PAGE.first_bank + bank - 1, lines.pages, level)
    end
    local current = S.lib.types.of(voice_idx)
    for x, record in ipairs(S.lib.types.list()) do
      if x > FADERS_PAGE.line_keys then break end
      led(x, lines.types, (current and record.key == current.key) and levels.picked or levels.unpicked)
    end
    for other = 1, NUM_VOICES do led(other, lines.voices, other == voice_idx and levels.picked or levels.unpicked) end
  end

  -- What the follow compares beside the fader lines: the grid voice, its
  -- page, its page count, the macros, the bank and the voice's type (a
  -- type or bank set off the grid redraws no grid of its own)
  local function signature(pane)
    local voice_idx = S.grid_voice_select
    local current = S.lib.types.of(voice_idx)
    return table.concat({voice_idx, S.param_page, fader_page_count(voice_idx), tostring(shows_macros(pane)),
      S.lib.macros.bank(), current and current.key or "-"}, ",")
  end

  M.record = {
    name = "faders",
    index = S.constants.GRID_PAGES.faders,
    press = press,
    redraw = redraw,
    faders = faders,
    signature = signature,
  }
  S.register_grid_page(M.record)

  return M
end

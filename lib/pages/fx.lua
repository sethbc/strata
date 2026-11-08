-- lib/pages/fx.lua
-- The FX page: the effects params as a scrolling list under section labels
-- (S.FX_PAGE, the selected row S.fx_row), E2 row, E3 adjust, K3 on the
-- effect under the cursor: the delay's and reverb's bypass (their
-- delay_bypass and reverb_bypass params, lib/voice_mix.lua), the filter's
-- mix toggle. A bypassed effect's section row shows "byp". Registers its
-- S.registry.pages record. redraw_fx stays global.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local FL = S.lib.ui_field_list

  local function percent(value)
    return string.format("%d%%", util.round(value * 100))
  end

  -- FX page: a scrolling list of the effects params under section labels
  -- (rows with selectable = false take no cursor stop). `format` is a
  -- string.format pattern or a function of the value, or nil to show the
  -- param's own string (the filter type's name); `effect` names the effect
  -- K3 acts on ("filter", "delay", "reverb"); master rows have none. A
  -- section row's `bypass` names the effect whose bypass it shows.
  S.FX_PAGE = {
    rows = {
      {label = "master", selectable = false},
      {label = "density", param_id = "master_density", format = "%.2f"},
      {label = "drift", param_id = "drift_amount", format = "%.3f"},
      {label = "filter", selectable = false},
      {label = "type", param_id = "filter_type", effect = "filter"},
      {label = "freq", param_id = "filter_freq", format = "%.0f Hz", effect = "filter"},
      {label = "res", param_id = "filter_res", format = "%.2f", effect = "filter"},
      {label = "mix", param_id = "filter_mix", format = percent, effect = "filter"},
      {label = "delay", selectable = false, bypass = "delay"},
      {label = "time", param_id = "delay_time", format = "%.3f s", effect = "delay"},
      {label = "fdbk", param_id = "delay_feedback", format = percent, effect = "delay"},
      {label = "mix", param_id = "delay_mix", format = percent, effect = "delay"},
      {label = "reverb", selectable = false, bypass = "reverb"},
      {label = "mix", param_id = "reverb_mix", format = percent, effect = "reverb"},
      {label = "size", param_id = "reverb_size", format = "%.2f", effect = "reverb"},
      {label = "damp", param_id = "reverb_damp", format = percent, effect = "reverb"}
    },
    visible_rows = 5,       -- rows at y 18-50, clear of the hint row at y 62
    first_row_y = 18,
    row_spacing = 8,
    param_x = 6,            -- param labels are indented under their section label
    section_level = 2,
    bypass_text = "byp",    -- right-aligned on a bypassed effect's section row
    bypass_level = 4
  }
  S.fx_row = 2               -- selected FX_PAGE.rows index (density)

  -- The FX_PAGE.rows index of a param's row (the layout states select rows
  -- by param id, so a row added above never moves them onto another; #114)
  local function row_of(param_id)
    for index, row in ipairs(S.FX_PAGE.rows) do
      if row.param_id == param_id then return index end
    end
    error("FX_PAGE has no row for " .. tostring(param_id))
  end

  local function draw_fx_row(row, y, selected, value_right)
    if not row.param_id then
      screen.level(S.FX_PAGE.section_level)
      screen.move(0, y)
      screen.text(row.label)
      if row.bypass and S.lib.voice_mix.bypassed(row.bypass) then
        screen.level(S.FX_PAGE.bypass_level)
        screen.move(value_right, y)
        screen.text_right(S.FX_PAGE.bypass_text)
      end
      return
    end
    local raw = params:get(row.param_id)
    local value
    if type(row.format) == "function" then
      value = row.format(raw)
    elseif row.format then
      value = string.format(row.format, raw)
    else
      value = params:string(row.param_id)
    end
    screen.level(selected and 15 or 4)
    screen.move(S.FX_PAGE.param_x, y)
    screen.text(row.label)
    screen.move(value_right, y)
    screen.text_right(value)
  end

  function redraw_fx()
    S.fx_row = FL.clamp(S.FX_PAGE.rows, S.fx_row)
    FL.draw(S.FX_PAGE.rows, S.fx_row, {visible = S.FX_PAGE.visible_rows,
      first_y = S.FX_PAGE.first_row_y, spacing = S.FX_PAGE.row_spacing}, draw_fx_row)
  end

  local function cursor_row()
    S.fx_row = FL.clamp(S.FX_PAGE.rows, S.fx_row)
    return S.FX_PAGE.rows[S.fx_row]
  end

  -- Whether K3 on the effect's rows would turn it off: the delay and
  -- reverb while not bypassed, the filter while its mix is above 0
  local function effect_on(effect)
    if S.lib.voice_mix.BYPASS[effect] then return not S.lib.voice_mix.bypassed(effect) end
    return params:get(effect .. "_mix") > 0
  end

  -- The hint row (redraw() draws it after the page)
  local function fx_hints(alt_held)
    local effect = cursor_row().effect
    if not effect then return "E3:value" end
    return "K3:" .. effect .. " " .. (effect_on(effect) and "bypass" or "on")
  end

  local function fx_enc(n, d)
    if n == 2 then
      S.fx_row = FL.move(S.FX_PAGE.rows, S.fx_row, d)
    elseif n == 3 then
      enc_param_delta(n, cursor_row().param_id, d)
    end
  end

  -- K3 on FX: toggle the delay's or reverb's bypass param (the engine
  -- frees the effect and its mix is kept), or set the filter's mix to 0 and
  -- back to its last non-zero mix (the filter is never freed); master rows
  -- do nothing
  local function fx_key(n)
    local effect = cursor_row().effect
    if n ~= 3 or not effect then return end
    local bypass = S.lib.voice_mix.BYPASS[effect]
    if bypass then
      params:set(bypass.param_id, 1 - params:get(bypass.param_id))
    else
      local mix_id = effect .. "_mix"
      params:set(mix_id, params:get(mix_id) > 0 and 0 or S.fx_last_mix[effect])
    end
  end

  -- The page's record, at FX's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/fx.lua's
  S.registry.pages[UI_PAGES.index.FX] = {name = "FX", draw = redraw_fx, hints = fx_hints,
    enc = fx_enc, key = fx_key,
    layout_states = {
      {name = "first row", setup = function() S.fx_row = row_of("master_density") end},
      {name = "last row", setup = function()
        params:set("reverb_damp", 1); params:set("reverb_mix", 1)
        S.fx_row = #S.FX_PAGE.rows
      end},
      {name = "filter freq", setup = function()
        params:set("filter_freq", 20000); S.fx_row = row_of("filter_freq")
      end},
      -- both section rows in view (the cursor on delay time), each with byp
      {name = "delay and reverb bypassed", setup = function()
        params:set("delay_bypass", 1); params:set("reverb_bypass", 1); params:set("delay_mix", 1)
        S.fx_row = row_of("delay_time")
      end}
    }}

  return M
end

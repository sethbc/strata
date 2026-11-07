-- lib/pages/fx.lua
-- The FX page: the effects params as a scrolling list under section labels
-- (S.FX_PAGE, the selected row S.fx_row), E2 row, E3 adjust, K3 bypass or
-- restore the effect under the cursor. Registers its S.registry.pages
-- record. redraw_fx stays global.

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
  -- K3 bypasses ("filter", "delay", "reverb"); master rows have none.
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
      {label = "delay", selectable = false},
      {label = "time", param_id = "delay_time", format = "%.3f s", effect = "delay"},
      {label = "fdbk", param_id = "delay_feedback", format = percent, effect = "delay"},
      {label = "mix", param_id = "delay_mix", format = percent, effect = "delay"},
      {label = "reverb", selectable = false},
      {label = "mix", param_id = "reverb_mix", format = percent, effect = "reverb"},
      {label = "size", param_id = "reverb_size", format = "%.2f", effect = "reverb"},
      {label = "damp", param_id = "reverb_damp", format = percent, effect = "reverb"}
    },
    visible_rows = 5,       -- rows at y 18-50, clear of the hint row at y 62
    first_row_y = 18,
    row_spacing = 8,
    param_x = 6,            -- param labels are indented under their section label
    section_level = 2
  }
  S.fx_row = 2               -- selected FX_PAGE.rows index (density)

  local function draw_fx_row(row, y, selected, value_right)
    if not row.param_id then
      screen.level(S.FX_PAGE.section_level)
      screen.move(0, y)
      screen.text(row.label)
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

  -- The hint row (redraw() draws it after the page)
  local function fx_hints(alt_held)
    local effect = cursor_row().effect
    if not effect then return "E3:value" end
    return "K3:" .. effect .. " " .. (params:get(effect .. "_mix") > 0 and "bypass" or "on")
  end

  local function fx_enc(n, d)
    if n == 2 then
      S.fx_row = FL.move(S.FX_PAGE.rows, S.fx_row, d)
    elseif n == 3 then
      enc_param_delta(n, cursor_row().param_id, d)
    end
  end

  -- K3 on FX: bypass the cursor row's effect (mix 0), or bring back its last
  -- non-zero mix; master rows do nothing
  local function fx_key(n)
    local effect = cursor_row().effect
    if n == 3 and effect then
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
      {name = "first row", setup = function() S.fx_row = 2 end},
      {name = "last row", setup = function()
        params:set("reverb_damp", 1); params:set("reverb_mix", 1)
        S.fx_row = #S.FX_PAGE.rows
      end},
      {name = "filter freq", setup = function()
        params:set("filter_freq", 20000); S.fx_row = 6
      end}
    }}

  return M
end

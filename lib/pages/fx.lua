-- lib/pages/fx.lua
-- The FX page: the effects params as a scrolling list (S.FX_PAGE, the
-- selected row S.fx_row), E2 row, E3 adjust, K3 filter bypass/on. Registers
-- its S.registry.pages record. redraw_fx stays global.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  -- FX page: a scrolling list of the effects params. E2 selects a row, E3
  -- adjusts it; format is a string.format pattern, or nil to show the param's
  -- own string (the filter type's name).
  S.FX_PAGE = {
    rows = {
      {label = "density", param_id = "master_density", format = "%.2f"},
      {label = "tape drift", param_id = "drift_amount", format = "%.3f"},
      {label = "filter type", param_id = "filter_type"},
      {label = "filter freq", param_id = "filter_freq", format = "%.0f Hz"},
      {label = "filter res", param_id = "filter_res", format = "%.2f"},
      {label = "filter mix", param_id = "filter_mix", format = "%.2f"},
      {label = "delay time", param_id = "delay_time", format = "%.3f s"},
      {label = "delay fdbk", param_id = "delay_feedback", format = "%.2f"},
      {label = "delay mix", param_id = "delay_mix", format = "%.2f"},
      {label = "reverb mix", param_id = "reverb_mix", format = "%.2f"},
      {label = "reverb size", param_id = "reverb_size", format = "%.2f"},
      {label = "reverb damp", param_id = "reverb_damp", format = "%.2f"}
    },
    visible_rows = 5,       -- rows at y 18-50, clear of the hint row at y 62
    first_row_y = 18,
    row_spacing = 8
  }
  S.fx_row = 1               -- selected FX_PAGE.rows index

  function redraw_fx()
    -- Keep one row above the selection in view, like the MAIN voice list
    local first_visible = util.clamp(S.fx_row - 1, 1, #S.FX_PAGE.rows - S.FX_PAGE.visible_rows + 1)
    for offset = 0, S.FX_PAGE.visible_rows - 1 do
      local row_index = first_visible + offset
      local row = S.FX_PAGE.rows[row_index]
      local y = S.FX_PAGE.first_row_y + offset * S.FX_PAGE.row_spacing
      local value = row.format and string.format(row.format, params:get(row.param_id))
        or params:string(row.param_id)
      screen.level(row_index == S.fx_row and 15 or 4)
      screen.move(0, y)
      screen.text(row.label)
      screen.move(127, y)
      screen.text_right(value)
    end

    draw_hints("K3:filter " .. (params:get("filter_mix") > 0 and "bypass" or "on"))
  end

  local function fx_enc(n, d)
    if n == 2 then
      S.fx_row = util.clamp(S.fx_row + d, 1, #S.FX_PAGE.rows)
    elseif n == 3 then
      params:delta(S.FX_PAGE.rows[S.fx_row].param_id, d)
    end
  end

  -- K3 on FX: bypass the filter (mix 0), or bring back its last non-zero mix
  local function fx_key(n)
    if n == 3 then
      params:set("filter_mix", params:get("filter_mix") > 0 and 0 or S.fx_filter_last_mix)
    end
  end

  -- The page's record, at FX's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]
  for index, name in ipairs(UI_PAGES) do
    if name == "FX" then
      S.registry.pages[index] = {name = name, draw = redraw_fx, enc = fx_enc, key = fx_key,
        key_release = S.lib.ui_keys.ignore_page_input}
    end
  end

  return M
end

-- lib/pages/fx.lua
-- The FX page: the effects params as a scrolling list under section labels
-- (S.FX_PAGE, the selected row S.fx_row): master, filter, delay, reverb and
-- shimmer (3.8 design §7.6). E2 row, E3 adjust, K3 on the effect under the
-- cursor: the delay's and reverb's bypass (their delay_bypass and
-- reverb_bypass params, lib/voice_mix.lua), the filter's mix toggle, and on
-- the delay's clear row the clear. ALT+K3 freezes or releases the delay or
-- reverb under the cursor (S.lib.fx_hold), never one bypassed or not
-- offered. A bypassed effect's section row shows "byp", a frozen one's
-- "frz", and a frozen delay's time row "held" after its label. While the
-- delay is synced (S.lib.delay_sync, 3.7) its time row shows the division
-- that plays and E3 turns delay_division; E3 turns sync
-- and a freeze on and off. The reverb's freeze is reached only through
-- S.lib.fx_hold.offered("reverb") (cut from 3.8, #819: its row shows --).
-- Registers its S.registry.pages record. redraw_fx stays global.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local FL = S.lib.ui_field_list

  local function percent(value)
    return string.format("%d%%", util.round(value * 100))
  end

  local function on_off(value)
    return value == 1 and "on" or "off"
  end

  -- FX page: a scrolling list of the effects params under section labels
  -- (rows with selectable = false take no cursor stop), written by hand
  -- (plan ruling 29). Every row has a `section` (the randomize's, ALT+K2);
  -- a section row's `bypass` and `freeze` name the effect whose bypass
  -- (byp) and freeze (frz) it shows. `format` is a string.format pattern or
  -- a function of the value, or nil to show the param's own string (the
  -- filter type's, the interval's name); `effect` names the effect K3 and
  -- ALT+K3 act on ("filter", "delay", "reverb"); master and shimmer rows
  -- have none. A row's `binary` makes E3 turn it on (up) and off (down);
  -- `synced` names the param the row turns while the delay plays a
  -- division, the row then showing S.lib.delay_sync.label(). A row's
  -- `frozen_mark` names the effect whose freeze marks it `held` after its
  -- label (never delay_sync's `held`, a scene apply's held send; the
  -- delay's time row: a frozen loop keeps the length it froze at, and the
  -- time shown is the one its release plays, #911). A `hold` row
  -- ("freeze", "clear") has no param_id: its param is its effect's in
  -- S.lib.fx_hold.FX_HOLD (freeze_id, clear_id), and none while the
  -- effect's freeze is not offered
  S.FX_PAGE = {
    rows = {
      {label = "master", section = "master", selectable = false},
      {label = "density", section = "master", param_id = "master_density", format = "%.2f"},
      {label = "drift", section = "master", param_id = "drift_amount", format = "%.3f"},
      {label = "filter", section = "filter", selectable = false},
      {label = "type", section = "filter", param_id = "filter_type", effect = "filter"},
      {label = "freq", section = "filter", param_id = "filter_freq", format = "%.0f Hz", effect = "filter"},
      {label = "res", section = "filter", param_id = "filter_res", format = "%.2f", effect = "filter"},
      {label = "mix", section = "filter", param_id = "filter_mix", format = percent, effect = "filter"},
      {label = "delay", section = "delay", selectable = false, bypass = "delay", freeze = "delay"},
      {label = "time", section = "delay", param_id = "delay_time", format = "%.3f s", effect = "delay",
        synced = "delay_division", frozen_mark = "delay"},
      {label = "fdbk", section = "delay", param_id = "delay_feedback", format = percent, effect = "delay"},
      {label = "level", section = "delay", param_id = "delay_mix", format = percent, effect = "delay"},  -- the return's
      {label = "sync", section = "delay", param_id = "delay_sync", format = on_off, effect = "delay", binary = true},
      {label = "ping", section = "delay", param_id = "delay_pingpong", format = percent, effect = "delay"},
      {label = "freeze", section = "delay", effect = "delay", hold = "freeze", format = on_off, binary = true},
      {label = "clear", section = "delay", effect = "delay", hold = "clear"},
      {label = "reverb", section = "reverb", selectable = false, bypass = "reverb", freeze = "reverb"},
      {label = "level", section = "reverb", param_id = "reverb_mix", format = percent, effect = "reverb"},
      {label = "size", section = "reverb", param_id = "reverb_size", format = "%.2f", effect = "reverb"},
      {label = "damp", section = "reverb", param_id = "reverb_damp", format = percent, effect = "reverb"},
      {label = "from delay", section = "reverb", param_id = "delay_to_reverb", format = percent, effect = "reverb"},
      {label = "freeze", section = "reverb", effect = "reverb", hold = "freeze", format = on_off, binary = true},
      {label = "shimmer", section = "shimmer", selectable = false},
      {label = "interval", section = "shimmer", param_id = "shimmer_interval"},
      {label = "delay", section = "shimmer", param_id = "shimmer_delay", format = percent},
      {label = "reverb", section = "shimmer", param_id = "shimmer_reverb", format = percent}
    },
    visible_rows = 5,       -- rows at y 18-50, clear of the hint row at y 62
    first_row_y = 18,
    row_spacing = 8,
    param_x = 6,            -- param labels are indented under their section label
    section_level = 2,
    selected_level = 15,    -- the cursor's row
    row_level = 4,          -- every other param row
    bypass_text = "byp",    -- right-aligned on a bypassed effect's section row
    frozen_text = "frz",    -- in its place on a frozen one's (a bypass ends a freeze)
    bypass_level = 4,       -- the level of both, and of the frozen mark
    frozen_mark_text = "held",  -- after a row's label while its `frozen_mark` effect is frozen (#911)
    frozen_mark_gap = 4,    -- px between the label and the frozen mark
    clear_text = "K3",      -- the clear row's value: K3 clears
    unavailable_text = "--",  -- a freeze not offered; the clear of a bypassed delay
    hints = {value = "E3:value", fine = "E3:fine", clear = "K3:clear", freeze = "K3:freeze",
      unfreeze = "K3:unfreeze"}
  }
  S.fx_row = 2               -- selected FX_PAGE.rows index (density)
  local FX = S.FX_PAGE

  -- The FX_PAGE.rows index of a param's row (the layout states select rows
  -- by param id, so a row added above never moves them onto another; #114)
  local function row_of(param_id)
    for index, row in ipairs(FX.rows) do
      if row.param_id == param_id then return index end
    end
    error("FX_PAGE has no row for " .. tostring(param_id))
  end

  -- The FX_PAGE.rows index of an effect's hold row ("freeze", "clear")
  local function hold_row_of(effect, hold)
    for index, row in ipairs(FX.rows) do
      if row.effect == effect and row.hold == hold then return index end
    end
    error("FX_PAGE has no " .. tostring(hold) .. " row for " .. tostring(effect))
  end

  -- The param a row shows and E3 turns: its synced one while the delay
  -- plays a division; a hold row's from S.lib.fx_hold, nil while its
  -- effect's freeze is not offered (the param may not exist: never read it)
  local function row_param_id(row)
    if row.hold then
      local hold = S.lib.fx_hold
      if not hold.offered(row.effect) then return nil end
      return hold.FX_HOLD[row.effect][row.hold .. "_id"]
    end
    if row.synced and S.lib.delay_sync.playing() then return row.synced end
    return row.param_id
  end
  M.row_param_id = row_param_id

  -- Whether K3 on the row clears the delay: the clear row of a running delay
  local function clears(row)
    return row.hold == "clear" and not S.lib.voice_mix.bypassed(row.effect)
  end

  -- The text a param row shows at the value column
  local function row_value(row)
    if row.hold == "clear" then return clears(row) and FX.clear_text or FX.unavailable_text end
    local param_id = row_param_id(row)
    if not param_id then return FX.unavailable_text end
    if row.synced and param_id == row.synced then return S.lib.delay_sync.label() end
    local raw = params:get(param_id)
    if type(row.format) == "function" then return row.format(raw) end
    if row.format then return string.format(row.format, raw) end
    return params:string(param_id)
  end

  local function draw_fx_row(row, y, selected, value_right)
    if row.selectable == false then
      screen.level(FX.section_level)
      screen.move(0, y)
      screen.text(row.label)
      local mark
      if row.bypass and S.lib.voice_mix.bypassed(row.bypass) then
        mark = FX.bypass_text
      elseif row.freeze and S.lib.fx_hold.frozen(row.freeze) then
        mark = FX.frozen_text
      end
      if mark then
        screen.level(FX.bypass_level)
        screen.move(value_right, y)
        screen.text_right(mark)
      end
      return
    end
    local level = selected and FX.selected_level or FX.row_level
    screen.level(level)
    screen.move(FX.param_x, y)
    screen.text(row.label)
    if row.frozen_mark and S.lib.fx_hold.frozen(row.frozen_mark) then
      screen.level(FX.bypass_level)
      screen.move(FX.param_x + screen.text_extents(row.label) + FX.frozen_mark_gap, y)
      screen.text(FX.frozen_mark_text)
      screen.level(level)
    end
    screen.move(value_right, y)
    screen.text_right(row_value(row))
  end

  function redraw_fx()
    S.fx_row = FL.clamp(FX.rows, S.fx_row)
    FL.draw(FX.rows, S.fx_row, {visible = FX.visible_rows,
      first_y = FX.first_row_y, spacing = FX.row_spacing}, draw_fx_row)
  end

  local function cursor_row()
    S.fx_row = FL.clamp(FX.rows, S.fx_row)
    return FX.rows[S.fx_row]
  end

  -- Whether K3 on the effect's rows would turn it off: the delay and
  -- reverb while not bypassed, the filter while its mix is above 0
  local function effect_on(effect)
    if S.lib.voice_mix.BYPASS[effect] then return not S.lib.voice_mix.bypassed(effect) end
    return params:get(effect .. "_mix") > 0
  end

  -- The hint row (redraw() draws it after the page). With ALT held: K2's
  -- shared hint, then K3:freeze (K3:unfreeze while frozen) on a row of an
  -- effect ALT+K3 freezes, then E3:fine on a row that turns finely, a
  -- control param (an option, the filter type, keeps whole steps). K1 let
  -- go while ALT+K2 is down: K2's hint alone, since its release still acts
  local function fx_hints(alt_held)
    local record = S.registry.pages[UI_PAGES.index.FX]
    local row = cursor_row()
    if alt_held then
      local freeze, fine
      if S.lib.fx_hold.freezable(row.effect) then
        freeze = S.lib.fx_hold.frozen(row.effect) and FX.hints.unfreeze or FX.hints.freeze
      end
      local param_id = row_param_id(row)
      if param_id and params:lookup_param(param_id).controlspec then fine = FX.hints.fine end
      return S.lib.ui_alt.join(S.lib.ui_alt.k2_hint(record), freeze, fine)
    end
    if S.lib.ui_alt.k2_held() then return S.lib.ui_alt.join(S.lib.ui_alt.k2_hint(record)) end
    if clears(row) then return FX.hints.clear end
    local effect = row.effect
    if not effect then return FX.hints.value end
    return "K3:" .. effect .. " " .. (effect_on(effect) and "bypass" or "on")
  end

  local function fx_enc(n, d)
    if n == 2 then
      S.fx_row = FL.move(FX.rows, S.fx_row, d)
    elseif n == 3 then
      local row = cursor_row()
      if row.hold == "clear" then return end  -- K3 clears; E3 has nothing to turn
      local param_id = row_param_id(row)
      if not param_id then return end         -- a freeze not offered
      if row.binary then
        -- on with a turn up, off with a turn down (a toggle's delta would
        -- flip it either way)
        set_binary_param(param_id, d > 0 and 1 or 0)
      else
        enc_param_delta(n, param_id, d)
      end
    end
  end

  -- K3 on FX: on the clear row of a running delay, the clear
  -- (S.lib.fx_hold.clear); on every other delay and reverb row (a bypassed
  -- delay's clear row too) toggle the effect's bypass param (the engine
  -- frees the effect and its level is kept), or on a filter row set the
  -- filter's mix to 0 and back to its restore mix (params_setup's
  -- toggle_filter_mix; the filter is never freed); master and shimmer rows
  -- do nothing
  local function fx_key(n)
    local row = cursor_row()
    local effect = row.effect
    if n ~= 3 or not effect then return end
    if clears(row) then
      S.lib.fx_hold.clear()
      return
    end
    local bypass = S.lib.voice_mix.BYPASS[effect]
    if bypass then
      set_binary_param(bypass.param_id, 1 - params:get(bypass.param_id))  -- echoes to a MIDI map (#538)
    else
      S.lib.params_setup.toggle_filter_mix()
    end
  end

  -- ALT+K2 randomizes the section under the cursor (#557; S.lib.ui_alt.k2_up):
  -- master, filter, delay, reverb or shimmer, from the row's section.
  -- Ranges are musical, not the params' full ones; the filter's mix, the
  -- bypasses, the freezes and the clear are never drawn. A frequency or
  -- time draws evenly in octaves; an option uniformly. The specs are built
  -- once (the hint asks on every draw while ALT is held)
  local function octaves(low, high)
    return function() return low * (high / low) ^ math.random() end
  end
  local function between(low, high)
    return function() return low + math.random() * (high - low) end
  end
  local function any_option(param_id)
    return function() return math.random(#params:lookup_param(param_id).options) end
  end
  local FX_SECTION_DRAWS = {
    master = {{"master_density", between(0.5, 1.5)}, {"drift_amount", between(0, 0.03)}},
    filter = {{"filter_type", any_option("filter_type")},
      {"filter_freq", octaves(100, 10000)}, {"filter_res", between(0, 0.7)}},
    delay = {{"delay_time", octaves(0.05, 1.0)}, {"delay_feedback", between(0, 0.7)}, {"delay_mix", between(0, 0.5)}},
    reverb = {{"reverb_mix", between(0, 0.5)}, {"reverb_size", between(0.3, 0.95)}, {"reverb_damp", between(0, 1)},
      {"delay_to_reverb", between(0.3, 1)}},
    shimmer = {{"shimmer_interval", any_option("shimmer_interval")}, {"shimmer_delay", between(0, 0.5)},
      {"shimmer_reverb", between(0, 0.4)}}
  }
  local FX_SECTION_SPECS = {}
  for section, entries in pairs(FX_SECTION_DRAWS) do
    local draws = {}
    for index, entry in ipairs(entries) do draws[index] = {id = entry[1], draw = entry[2]} end
    FX_SECTION_SPECS[section] = {page = UI_PAGES.index.FX, section = section, draws = draws}
  end

  local function fx_randomize_section()
    return FX_SECTION_SPECS[cursor_row().section]
  end

  -- The frame clock redraws FX while ALT+K2 is down, so its hint turns to
  -- K2:cancel at the hold time
  local function fx_animates()
    return S.lib.ui_alt.k2_held()
  end

  -- ALT+K2 acts on release; the press only redraws (its time is the
  -- dispatcher's, S.key_press_at); no hold action.
  -- ALT+K3 freezes or releases the cursor row's effect, if it freezes
  -- (fx_hold's toggle; its param's action redraws)
  local function fx_alt_key(n)
    if n == 2 then
      request_redraw()
    elseif n == 3 then
      local effect = cursor_row().effect
      S.lib.fx_hold.toggle(effect)  -- nothing unless S.lib.fx_hold.freezable(effect)
    end
  end
  local function fx_alt_key_release(n)
    if n == 2 then S.lib.ui_alt.k2_up(S.registry.pages[UI_PAGES.index.FX]) end
  end

  -- The shimmer layout states: the interval at the option named `name`, or
  -- at its widest name on screen (oct down, 38 px), and both amounts at 100%
  local function shimmer_at(name)
    local options = params:lookup_param("shimmer_interval").options
    local chosen = 1
    for index, option in ipairs(options) do
      if option == name or (not name and screen.text_extents(option) > screen.text_extents(options[chosen])) then
        chosen = index
      end
    end
    params:set("shimmer_interval", chosen)
    params:set("shimmer_delay", 1); params:set("shimmer_reverb", 1)
  end

  -- The page's record, at FX's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/fx.lua's
  S.registry.pages[UI_PAGES.index.FX] = {name = "FX", draw = redraw_fx, hints = fx_hints,
    enc = fx_enc, key = fx_key, alt_key = fx_alt_key, alt_key_release = fx_alt_key_release,
    randomize_section = fx_randomize_section, animates = fx_animates,
    layout_states = {
      {name = "first row", setup = function() S.fx_row = row_of("master_density") end},
      -- the shimmer section at its widest, its last row under the cursor
      {name = "last row", setup = function()
        shimmer_at(nil)
        S.fx_row = #FX.rows
      end},
      {name = "filter freq", setup = function()
        params:set("filter_freq", 20000); S.fx_row = row_of("filter_freq")
      end},
      -- both bypassed: the delay's section row with byp in view (the cursor
      -- on delay time), then the reverb's (on reverb level); the delay's
      -- seven rows keep the two out of one view
      {name = "delay and reverb bypassed", setup = function()
        params:set("delay_bypass", 1); params:set("reverb_bypass", 1); params:set("delay_mix", 1)
        S.fx_row = row_of("delay_time")
      end},
      {name = "reverb bypassed in view", setup = function()
        params:set("delay_bypass", 1); params:set("reverb_bypass", 1); params:set("reverb_mix", 1)
        S.fx_row = row_of("reverb_mix")
      end},
      -- the time row's widest label: 1 bar at 20 BPM, halved twice
      {name = "delay synced and halved", setup = function()
        params:set("delay_sync", 1); params:set("delay_division", #S.constants.DIVISIONS.names)
        params:set("clock_tempo", 20)
        S.fx_row = row_of("delay_time")
      end},
      -- ALT's widest hint, on a row that turns finely: K2:cancel E3:fine
      {name = "ALT+K2 held past the hold time", setup = function(context)
        S.fx_row = row_of("filter_freq")
        key(1, 1); key(2, 1)
        context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
      end},
      -- 3.8: frz on the delay's section row (the cursor on delay time),
      -- held on its time row (#911)
      {name = "delay frozen", setup = function()
        S.lib.fx_hold.toggle("delay")
        S.fx_row = row_of("delay_time")
      end},
      -- held beside the time row's widest label, 1 bar>1/4 (#911)
      {name = "delay frozen, synced and halved", setup = function()
        params:set("delay_sync", 1); params:set("delay_division", #S.constants.DIVISIONS.names)
        params:set("clock_tempo", 20)
        S.lib.fx_hold.toggle("delay")
        S.fx_row = row_of("delay_time")
      end},
      {name = "the clear row", setup = function() S.fx_row = hold_row_of("delay", "clear") end},
      -- the widest hint: K2:cancel K3:unfreeze E3:fine (122 px)
      {name = "ALT on a frozen delay row", setup = function(context)
        S.lib.fx_hold.toggle("delay")
        S.fx_row = row_of("delay_feedback")
        key(1, 1); key(2, 1)
        context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
      end},
      {name = "shimmer at oct+5th and 100%", setup = function()
        shimmer_at("oct+5th")
        S.fx_row = row_of("shimmer_interval")
      end}
    }}

  return M
end

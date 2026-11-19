-- lib/grid/pages/fx.lua
-- Grid page 7, FX (3.8, design §10.9): lines 1-5 the five faders of the
-- picked set (the delay: its time, or its division while synced,
-- feedback, level, ping-pong and shimmer; the reverb: level, size, damp,
-- shimmer and the delay into it; the master: the filter's cutoff,
-- resonance and mix, density and drift); line 6 the set keys (x 1-3) and
-- shimmer's interval (x 5-9); line 7 the delay's bypass, sync, freeze and
-- clear (x 1-4), the reverb's bypass and freeze (x 6-7: the freeze dark
-- and dead while S.lib.fx_hold offers none), the filter's three types (x
-- 9-11) and its mix on or off (x 12). Every key sets a param (through
-- S.lib.fx_hold, set_binary_param or toggle_filter_mix where they own
-- it); the page sends no engine command. Written in pane coordinates
-- (lib/grid/pane.lua), so it is the same on every layout; the picked set
-- is pane.state()'s, per port

return function(S)
  local M = {}
  local LEVELS = S.constants.GRID_LEVELS

  -- The lines, the keys (pane x) and the levels; each set's five fader
  -- ids, line 1 to 5 (the delay's time line through
  -- S.lib.grid_faders.fx_fader_id: the division while synced)
  local FX_PAGE = {
    lines = {picks = 6, keys = 7},
    line_keys = S.lib.grid_pane.LINE_KEYS,
    sets = {
      {name = "delay", ids = {"delay_time", "delay_feedback", "delay_mix", "delay_pingpong", "shimmer_delay"}},
      {name = "reverb", ids = {"reverb_mix", "reverb_size", "reverb_damp", "shimmer_reverb", "delay_to_reverb"}},
      {name = "master", ids = {"filter_freq", "filter_res", "filter_mix", "master_density", "drift_amount"}},
    },
    default_set = 1,
    first_set = 1,        -- line 6: set n at x first_set + n - 1
    first_interval = 5,   -- line 6: interval i at x first_interval + i - 1
    keys = {               -- line 7
      bypass = {delay = 1, reverb = 6},
      freeze = {delay = 3, reverb = 7},
      sync = 2,
      clear = 4,
      first_filter_type = 9,  -- filter type t at x first_filter_type + t - 1
      filter_mix = 12,
    },
    ids = {sync = "delay_sync", filter_type = "filter_type", filter_mix = "filter_mix"},
    levels = {picked = LEVELS.picked, other = LEVELS.unpicked, on = LEVELS.picked, off = LEVELS.unpicked,
      playing = 8, bypassed = 2, held = 15, dark = 0},
  }
  M.FX_PAGE = FX_PAGE

  local lines, keys, ids, levels = FX_PAGE.lines, FX_PAGE.keys, FX_PAGE.ids, FX_PAGE.levels

  local function exists(param_id) return type(param_id) == "string" and params.lookup[param_id] ~= nil end

  local function whole_in(n, low, high)
    return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
  end

  -- The port's picked set (1 delay, 2 reverb, 3 master)
  local function set_of(pane)
    local set = pane.state().set
    if whole_in(set, 1, #FX_PAGE.sets) then return set end
    return FX_PAGE.default_set
  end

  local function interval_id() return S.lib.shimmer.SHIMMER.interval_id end
  local function interval_count() return #S.lib.shimmer.SHIMMER.ratios end
  local function filter_type_count() return #params:lookup_param(ids.filter_type).options end

  -- Lines 1-5 for the params that exist (the engine's draw reads
  -- fader_position outside its containment, so no id that is no param is
  -- listed)
  local function faders(pane)
    local found = {}
    for line, id in ipairs(FX_PAGE.sets[set_of(pane)].ids) do
      local shown = S.lib.grid_faders.fx_fader_id(id)
      if exists(shown) then found[#found + 1] = {line = line, first = 1, keys = FX_PAGE.line_keys, id = shown} end
    end
    return found
  end

  -- The effect a bypass or freeze key of line 7 names, or nil
  local function effect_at(map, x)
    for effect, key_x in pairs(map) do
      if key_x == x then return effect end
    end
    return nil
  end

  -- A bypass key toggles its effect's bypass param (whose action ends the
  -- freeze first), through set_binary_param so a mapped controller follows
  local function toggle_bypass(effect)
    local voice_mix = S.lib.voice_mix
    set_binary_param(voice_mix.BYPASS[effect].param_id, voice_mix.bypassed(effect) and 0 or 1)
  end

  local function picks_key(pane, x)
    local set = x - FX_PAGE.first_set + 1
    local interval = x - FX_PAGE.first_interval + 1
    if whole_in(set, 1, #FX_PAGE.sets) then
      pane.state().set = set
    elseif whole_in(interval, 1, interval_count()) then
      params:set(interval_id(), interval)
    end
  end

  local function effects_key(x)
    local fx_hold = S.lib.fx_hold
    local filter_type = x - keys.first_filter_type + 1
    local bypass, freeze = effect_at(keys.bypass, x), effect_at(keys.freeze, x)
    if bypass then
      toggle_bypass(bypass)
    elseif freeze then
      -- nothing while the effect has no freeze (its param is never read)
      if fx_hold.offered(freeze) then fx_hold.toggle(freeze) end
    elseif x == keys.sync then
      set_binary_param(ids.sync, params:get(ids.sync) == 1 and 0 or 1)
    elseif x == keys.clear then
      fx_hold.clear()
    elseif whole_in(filter_type, 1, filter_type_count()) then
      params:set(ids.filter_type, filter_type)
    elseif x == keys.filter_mix then
      S.lib.params_setup.toggle_filter_mix()
    end
  end

  -- A press acts at its press; a release does nothing (the fader lines'
  -- keys are the engine's)
  local function press(pane, x, y, z)
    if z ~= 1 or not whole_in(x, 1, FX_PAGE.line_keys) then return end
    if y == lines.picks then
      picks_key(pane, x)
    elseif y == lines.keys then
      effects_key(x)
    end
  end

  local function on_off(on) return on and levels.on or levels.off end

  -- A freeze key's level: dark while its effect has no freeze, the param
  -- read only through offered and frozen
  local function freeze_level(effect)
    local fx_hold = S.lib.fx_hold
    if not fx_hold.offered(effect) then return levels.dark end
    return on_off(fx_hold.frozen(effect))
  end

  local function redraw(pane, led)
    local set = set_of(pane)
    for n = 1, #FX_PAGE.sets do
      led(FX_PAGE.first_set + n - 1, lines.picks, n == set and levels.picked or levels.other)
    end
    local interval = params:get(interval_id())
    for n = 1, interval_count() do
      led(FX_PAGE.first_interval + n - 1, lines.picks, n == interval and levels.picked or levels.other)
    end
    for effect, x in pairs(keys.bypass) do
      led(x, lines.keys, S.lib.voice_mix.bypassed(effect) and levels.bypassed or levels.playing)
    end
    for effect, x in pairs(keys.freeze) do led(x, lines.keys, freeze_level(effect)) end
    led(keys.sync, lines.keys, on_off(params:get(ids.sync) == 1))
    led(keys.clear, lines.keys, pane.held(keys.clear, lines.keys) and levels.held or levels.off)
    local filter_type = params:get(ids.filter_type)
    for n = 1, filter_type_count() do
      led(keys.first_filter_type + n - 1, lines.keys, n == filter_type and levels.picked or levels.other)
    end
    led(keys.filter_mix, lines.keys, on_off(params:get(ids.filter_mix) > 0))
  end

  -- What the drift tick's follow compares beside the fader lines: the
  -- interval, the bypasses, sync (whose action redraws, but not during a
  -- scene transition), the reverb's freeze (only while offered), the
  -- filter's type and whether its mix is above 0. The delay's freeze has
  -- no term (its action always redraws the grids), nor the set (it
  -- changes only at a press, which repaints)
  local function signature()
    local voice_mix, fx_hold = S.lib.voice_mix, S.lib.fx_hold
    local parts = {params:get(interval_id()), params:get(ids.sync), params:get(ids.filter_type),
      tostring(params:get(ids.filter_mix) > 0)}
    for _, effect in ipairs(voice_mix.BYPASS_ORDER) do
      parts[#parts + 1] = tostring(voice_mix.bypassed(effect))
    end
    parts[#parts + 1] = fx_hold.offered("reverb") and tostring(fx_hold.frozen("reverb")) or "-"
    return table.concat(parts, ",")
  end

  M.record = {
    name = "fx",
    index = S.constants.GRID_PAGES.fx,
    press = press,
    redraw = redraw,
    faders = faders,
    signature = signature,
  }
  S.register_grid_page(M.record)

  return M
end

-- lib/pages/lfo.lua
-- The LFO page: one row per LFO (shape, phase dot, destination, depth) and,
-- under the selected LFO's row, a strip of its seven fields (destination,
-- shape, mode, rate, depth, offset, on/off). E2 moves along the strip, E3
-- edits the field (ALT+E3 on the destination jumps a group), K2/K3 select
-- the LFO, ALT+K2 resets the field, ALT+K3 and the arc button turn the LFO
-- on and off. Registers its S.registry.pages record. The strip's cursor is
-- S.lfo_field (an index into LFO_FIELDS). The functions that were global
-- stay global, as do lfo_dest_group_starts and lfo_dest_group_jump;
-- lfo_running (for the arc rings), row_top, strip_y and layout (LFO_PAGE,
-- for the tests) are fields of this module's table (S.lib.pages_lfo).

return function(S)
  local M = {}
  local NUM_LFOS = S.constants.NUM_LFOS
  local NUM_VOICES = S.constants.NUM_VOICES
  local UI_PAGES = S.constants.UI_PAGES

  -- LFO page: one row per LFO from y 12 (clear of the header): "L<n>", one
  -- cycle of its shape (64 px), a dot at the estimated phase and last raw
  -- value while it runs, then its destination and state/depth right-aligned.
  -- The selected LFO's field strip sits under its row, and the rows below it
  -- move down to make room, so everything ends by y 55, above the hint row
  local LFO_PAGE = {
    row_first_y = 12,   -- top of LFO 1's row
    row_spacing = 12,
    wave_height = 10,   -- shape value 1 at the row top, 0 at top + 10
    wave_x = 12,
    wave_width = 64,
    strip_baseline = 18,  -- the strip's text baseline, below its row's top
    strip_height = 8,     -- how far the rows under the strip move down
    strip_gap = 6,        -- px between two fields
    strip_right = 127,    -- the strip's right edge (the ">" marker ends here)
    -- the random shape holds a new value each half cycle; drawn as two steps
    random_display_levels = {0.75, 0.3}
  }
  M.layout = LFO_PAGE

  -- The strip's cursor: the field E3 edits
  S.lfo_field = 1

  local function lfo_running(n)
    return params:get("lfo_" .. n) == 2
  end
  M.lfo_running = lfo_running

  -- The rate field edits the period param of the LFO's mode
  local function rate_param_id(n)
    if params:string("lfo_mode_" .. n) == "clocked" then return "lfo_clocked_" .. n end
    return "lfo_free_" .. n
  end

  -- The strip's fields, in order: label (the hint row's E3:<label>), the
  -- param E3 edits for LFO n, and the value the strip shows
  local LFO_FIELDS = {
    {label = "dest", param = function(n) return "strata_lfo" .. n .. "_dest" end,
      value = function(n) return S.LFO_DESTINATIONS[params:get("strata_lfo" .. n .. "_dest")].label end},
    {label = "shape", param = function(n) return "lfo_shape_" .. n end,
      value = function(n) return params:string("lfo_shape_" .. n) end},
    {label = "mode", param = function(n) return "lfo_mode_" .. n end,
      value = function(n) return params:string("lfo_mode_" .. n) end},
    -- the free period as the library stores it, or the clocked division
    {label = "rate", param = rate_param_id,
      value = function(n)
        if params:string("lfo_mode_" .. n) == "clocked" then return params:string("lfo_clocked_" .. n) end
        return string.format("%.1fs", params:get("lfo_free_" .. n))
      end},
    {label = "depth", param = function(n) return "lfo_depth_" .. n end,
      value = function(n) return string.format("%.0f%%", params:get("lfo_depth_" .. n)) end},
    -- norns' lib/lfo.lua adds the offset to its scaled value, which apply_lfo sends
    {label = "offset", param = function(n) return "lfo_offset_" .. n end,
      value = function(n)
        local offset = params:get("lfo_offset_" .. n)
        return string.format(offset > 0 and "+%.0f%%" or "%.0f%%", offset)
      end},
    {label = "on/off", param = function(n) return "lfo_" .. n end,
      value = function(n) return lfo_running(n) and "on" or "off" end}
  }
  local DEST_FIELD, RATE_FIELD, STATE_FIELD = 1, 4, #LFO_FIELDS

  -- Top of LFO n's row: the rows under the selected LFO's sit below its strip
  local function row_top(n)
    local top = LFO_PAGE.row_first_y + (n - 1) * LFO_PAGE.row_spacing
    if n > S.selected_lfo then top = top + LFO_PAGE.strip_height end
    return top
  end
  M.row_top = row_top

  -- The strip's text baseline
  local function strip_y()
    return row_top(S.selected_lfo) + LFO_PAGE.strip_baseline
  end
  M.strip_y = strip_y

  -- The destination groups' first indices into S.LFO_DESTINATIONS: none (1),
  -- the globals (2), each voice's "v<i> main" (found by label), then the
  -- registered destinations after the built-in ones (lib/lfos.lua's
  -- S.lib.lfos.BUILT_IN_DESTINATIONS), as one more group
  function lfo_dest_group_starts()
    local destinations = S.LFO_DESTINATIONS
    local starts = {1, 2}
    local voice_starts = {}
    for index, destination in ipairs(destinations) do
      local voice = destination.label:match("^v(%d+) main$")
      if voice then voice_starts[tonumber(voice)] = index end
    end
    for voice = 1, NUM_VOICES do
      if voice_starts[voice] then table.insert(starts, voice_starts[voice]) end
    end
    local built_in = S.lib.lfos.BUILT_IN_DESTINATIONS
    if #destinations > built_in then table.insert(starts, built_in + 1) end
    return starts
  end

  -- The destination one group on from index: the next group start above it
  -- (d > 0) or the last one below it (d < 0); index itself at either end
  function lfo_dest_group_jump(index, d)
    local starts = lfo_dest_group_starts()
    if d > 0 then
      for _, start in ipairs(starts) do
        if start > index then return start end
      end
    elseif d < 0 then
      for position = #starts, 1, -1 do
        if starts[position] < index then return starts[position] end
      end
    end
    return index
  end

  -- Turn LFO n on or off (lib/lfos.lua keeps its offset across on/off)
  local function set_lfo_running(n, on)
    params:set("lfo_" .. n, on and 2 or 1)
  end

  local function toggle_selected_lfo()
    set_lfo_running(S.selected_lfo, not lfo_running(S.selected_lfo))
  end

  -- K2/K3: the previous or next LFO. Arc ring 4's carried ticks were for
  -- the old LFO's clocked rate
  local function select_lfo_by(d)
    local previous_lfo = S.selected_lfo
    S.selected_lfo = util.clamp(S.selected_lfo + d, 1, NUM_LFOS)
    if S.selected_lfo ~= previous_lfo then forget_arc_ticks("lfo:4") end
  end

  -- One point (0..1) of a shape at a phase, as the library's process_lfo
  -- computes its raw value
  function lfo_shape_value(shape, phase)
    if shape == "sine" then
      return (math.sin(2 * math.pi * phase) + 1) / 2
    elseif shape == "tri" then
      return phase < 0.5 and phase / 0.5 or 1 - (phase - 0.5) / 0.5
    elseif shape == "up" then
      return phase
    elseif shape == "down" then
      return 1 - phase
    elseif shape == "square" then
      return phase < 0.5 and 1 or 0
    end
    return LFO_PAGE.random_display_levels[phase < 0.5 and 1 or 2]  -- random
  end

  local function draw_lfo_row(n)
    local top = row_top(n)
    local bottom = top + LFO_PAGE.wave_height
    local running = lfo_running(n)
    local label_level = n == S.selected_lfo and 15 or 4

    screen.level(label_level)
    screen.move(0, top + 7)
    screen.text("L" .. n)

    local shape = params:string("lfo_shape_" .. n)
    screen.level(running and 6 or 2)
    for px = 0, LFO_PAGE.wave_width - 1 do
      local y = bottom - lfo_shape_value(shape, px / (LFO_PAGE.wave_width - 1)) * LFO_PAGE.wave_height
      if px == 0 then
        screen.move(LFO_PAGE.wave_x, y)
      else
        screen.line(LFO_PAGE.wave_x + px, y)
      end
    end
    screen.stroke()

    if running and S.lfo_last_raw[n] then
      local x = util.round(LFO_PAGE.wave_x + lfo_phase_estimate(n) * (LFO_PAGE.wave_width - 1))
      local y = util.round(bottom - S.lfo_last_raw[n] * LFO_PAGE.wave_height)
      screen.level(15)
      screen.rect(x - 1, y - 1, 3, 3)
      screen.fill()
    end

    screen.level(label_level)
    screen.move(127, top + 5)
    screen.text_right(S.LFO_DESTINATIONS[params:get("strata_lfo" .. n .. "_dest")].label)
    screen.move(127, top + 11)
    screen.text_right((running and "on " or "off ") .. string.format("%.0f%%", params:get("lfo_depth_" .. n)))
  end

  -- The strip's view: the first and last field drawn, as many as fit with
  -- the cursor's among them, starting as far left as that allows. A "<"
  -- marker (and a gap) takes the left end when fields lie off to the left,
  -- a ">" the right end when they lie off to the right
  local function strip_view(widths, cursor, marker_width)
    local count = #widths
    for first = 1, cursor do
      local x = first > 1 and (marker_width + LFO_PAGE.strip_gap) or 0
      local last = first - 1
      for index = first, count do
        local reserve = index < count and (LFO_PAGE.strip_gap + marker_width) or 0
        if x + widths[index] + reserve > LFO_PAGE.strip_right then break end
        last = index
        x = x + widths[index] + LFO_PAGE.strip_gap
      end
      if last >= cursor then return first, last end
    end
    return cursor, cursor
  end

  -- The selected LFO's fields on one line: the cursor's at 15, the others
  -- and the markers at 4
  local function draw_strip()
    local n = S.selected_lfo
    local values, widths = {}, {}
    for index, field in ipairs(LFO_FIELDS) do
      values[index] = field.value(n)
      widths[index] = screen.text_extents(values[index])
    end
    local marker_width = math.max(screen.text_extents("<"), screen.text_extents(">"))
    local first, last = strip_view(widths, S.lfo_field, marker_width)
    local y = strip_y()
    local x = 0
    screen.level(4)
    if first > 1 then
      screen.move(0, y)
      screen.text("<")
      x = marker_width + LFO_PAGE.strip_gap
    end
    for index = first, last do
      screen.level(index == S.lfo_field and 15 or 4)
      screen.move(x, y)
      screen.text(values[index])
      x = x + widths[index] + LFO_PAGE.strip_gap
    end
    if last < #LFO_FIELDS then
      screen.level(4)
      screen.move(LFO_PAGE.strip_right, y)
      screen.text_right(">")
    end
  end

  function redraw_lfo()
    for n = 1, NUM_LFOS do
      draw_lfo_row(n)
    end
    draw_strip()
  end

  -- The hint row (redraw() draws it after the page)
  local function lfo_hints(alt_held)
    if alt_held then
      -- on the destination, ALT+E3 jumps a group
      local jump = S.lfo_field == DEST_FIELD and " E3:group" or ""
      return "K2:reset K3:" .. (lfo_running(S.selected_lfo) and "off" or "on") .. jump
    end
    return "K2/K3:lfo E3:" .. LFO_FIELDS[S.lfo_field].label
  end

  -- E2 moves along the strip; E3 edits the cursor's field of the selected
  -- LFO (ALT+E3 fine on a control param: the free period)
  local function lfo_enc(n, d)
    if n == 2 then
      S.lfo_field = util.clamp(S.lfo_field + d, 1, #LFO_FIELDS)
    elseif n == 3 then
      local lfo = S.selected_lfo
      if S.lfo_field == STATE_FIELD then
        set_lfo_running(lfo, d > 0)
      else
        enc_param_delta(n, LFO_FIELDS[S.lfo_field].param(lfo), d)
      end
    end
  end

  -- ALT+E3 on the destination jumps a group per detent (none, global, then
  -- v1 ... v7); anything else goes on to lfo_enc
  local function lfo_alt_enc(n, d)
    if n ~= 3 or S.lfo_field ~= DEST_FIELD then return false end
    local dest_id = LFO_FIELDS[DEST_FIELD].param(S.selected_lfo)
    local index = params:get(dest_id)
    for _ = 1, math.abs(d) do
      index = lfo_dest_group_jump(index, d)
    end
    params:set(dest_id, index)
    return true
  end

  local function lfo_key(n)
    if n == 2 then
      select_lfo_by(-1)
    elseif n == 3 then
      select_lfo_by(1)
    end
  end

  -- ALT+K2 resets the cursor's field to its default; ALT+K3 turns the
  -- selected LFO on or off
  local function lfo_alt_key(n)
    local lfo = S.selected_lfo
    if n == 2 then
      local param_id = LFO_FIELDS[S.lfo_field].param(lfo)
      if S.lfo_field == STATE_FIELD then
        set_lfo_running(lfo, param_default(param_id) == 2)
      else
        params:set(param_id, param_default(param_id))
      end
    elseif n == 3 then
      toggle_selected_lfo()
    end
  end

  -- The layout test's states: each LFO selected, each strip field under the
  -- cursor (with wide values), clocked and free
  local function layout_state(name, lfo, field, setup)
    return {name = name, setup = function()
      S.selected_lfo = lfo
      S.lfo_field = field
      if setup then setup() end
    end}
  end
  local layout_states = {}
  for n = 1, NUM_LFOS do
    table.insert(layout_states, layout_state("lfo" .. n, n, DEST_FIELD, function()
      params:set("strata_lfo" .. n .. "_dest", #S.LFO_DESTINATIONS)
      params:set("lfo_" .. n, 2)
    end))
  end
  local field_names = {"dest", "shape", "mode", "rate", "depth", "offset", "state"}
  for field, name in ipairs(field_names) do
    table.insert(layout_states, layout_state("field-" .. name, 2, field, function()
      params:set("strata_lfo2_dest", #S.LFO_DESTINATIONS)
      params:set("lfo_shape_2", 4)       -- random
      params:set("lfo_free_2", 300)
      params:set("lfo_depth_2", 100)
      params:set("lfo_2", 2)
      params:set("lfo_offset_2", -50)
    end))
  end
  table.insert(layout_states, layout_state("clocked", 3, RATE_FIELD, function()
    params:set("lfo_mode_3", 1)
    params:set("lfo_clocked_3", 4)       -- "5/16", the widest division
  end))
  table.insert(layout_states, layout_state("free", 1, RATE_FIELD, function()
    params:set("lfo_free_1", 0.1)
  end))

  -- The page's record, at LFO's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/lfo.lua's
  S.registry.pages[UI_PAGES.index.LFO] = {name = "LFO", draw = redraw_lfo, hints = lfo_hints,
    enc = lfo_enc, alt_enc = lfo_alt_enc, key = lfo_key, alt_key = lfo_alt_key,
    arc_button = toggle_selected_lfo, layout_states = layout_states}

  return M
end

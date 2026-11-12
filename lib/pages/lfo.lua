-- lib/pages/lfo.lua
-- The LFO page: a window of three of the six LFOs (the selected one and its
-- neighbors, lib/lfos.lua's window), one row each (shape, phase dot,
-- destination, depth), and under the selected LFO's row a strip of its
-- twelve fields (destination, shape, mode, rate, depth, offset, phase, rate
-- mod, rate amt, depth mod, depth amt, on/off). E2 moves along the strip, E3
-- edits the field (ALT+E3 on the destination jumps a group, on the rate is
-- fine, on a percent keeps whole steps), K2/K3 select the LFO, ALT+K2 on
-- release randomizes the selected LFO's shape, rate or division and phase
-- (again within 5 s to undo; held past the hold time, it resets the field),
-- ALT+K3 and the arc button turn the LFO on and off. Registers its
-- S.registry.pages record. The strip's cursor is S.lfo_field (an index into
-- LFO_FIELDS). The functions that were global stay global, as do
-- lfo_dest_group_starts and lfo_dest_group_jump; lfo_running, show_lfo,
-- select_lfo_by, row_top, strip_y and layout (LFO_PAGE, for the tests) are
-- fields of this module's table (S.lib.pages_lfo).

return function(S)
  local M = {}
  local NUM_LFOS = S.constants.NUM_LFOS
  local UI_PAGES = S.constants.UI_PAGES

  -- LFO page: one row per LFO of the window from y 11 (clear of the header):
  -- "L<n>", one cycle of its shape (wave_width px), a dot at its phase and
  -- value while it runs, then its destination and state/depth
  -- right-aligned; the window's mark ("4-6") right of the first row's wave,
  -- on its lower line. The selected LFO's field strip sits under its row,
  -- and the rows below it move down to make room, so everything ends by y
  -- 55, above the hint row. Rows 13 px apart: a destination (baseline top +
  -- 4) sits 6 px under the row above's state text, and 7 px over its own
  -- (top + 11), which its descender clears (#422). The wave stops short of
  -- the mark, which stops short of the widest state text ("off 100% R")
  local LFO_PAGE = {
    row_first_y = 11,   -- top of the window's first row
    row_spacing = 13,
    wave_height = 10,   -- shape value 1 at the row top, 0 at top + 10
    wave_x = 12,
    wave_width = 52,
    mark_x = 66,          -- the window mark, left-aligned on the first row's lower line
    strip_baseline = 18,  -- the strip's text baseline, below its row's top
    strip_height = 8,     -- how far the rows under the strip move down
    strip_gap = 6,        -- px between two fields
    strip_right = 127,    -- the strip's right edge (the ">" marker ends here)
    window_rows = 3,
    -- the random shapes drawn as breakpoints {phase, u} (their real values
    -- are drawn per cycle; the dot shows them)
    random_displays = {
      ["s&h"] = {{0, 0.75}, {0.5, 0.75}, {0.5, 0.3}, {1, 0.3}},
      smooth = {{0, 0.3}, {0.5, 0.75}, {1, 0.4}},
      drunk = {{0, 0.5}, {0.25, 0.6}, {0.5, 0.45}, {0.75, 0.55}, {1, 0.5}},
    },
    -- ALT+K2's randomize: the free rate even in octaves over free_random,
    -- any division, a whole phase 0-100
    free_random = {0.05, 10},
  }
  M.layout = LFO_PAGE

  local function lfos() return S.lib.lfos end
  local function lfo_param(n, field) return S.lib.lfos.param_id(n, field) end

  -- The strip's cursor: the field E3 edits
  S.lfo_field = 1

  local function lfo_running(n)
    return params:get(lfo_param(n)) == 1
  end
  M.lfo_running = lfo_running

  local function signed(value)
    return string.format(value > 0 and "+%.0f%%" or "%.0f%%", value)
  end

  -- The rate field: the rate in Hz (free) or the division (clocked), and
  -- "max" after it when it runs in Lua above 10 Hz
  local function rate_text(n)
    local text
    if lfos().is_clocked(n) then
      text = params:string(lfo_param(n, "division"))
    else
      text = string.format("%.3gHz", params:get(lfo_param(n, "rate")))
    end
    if lfos().capped(n) then text = text .. " max" end
    return text
  end

  -- The strip's fields, in order: label (the hint row's E3:<label>), the
  -- param E3 edits for LFO n (nil: the on/off field), whether ALT+E3 keeps
  -- whole steps (a percent), and the value the strip shows
  local LFO_FIELDS = {
    {label = "dest", param = function(n) return lfo_param(n, "dest") end, value = function(n) return lfos().label(n) end},
    {label = "shape", param = function(n) return lfo_param(n, "shape") end,
      value = function(n) return params:string(lfo_param(n, "shape")) end},
    {label = "mode", param = function(n) return lfo_param(n, "mode") end,
      value = function(n) return params:string(lfo_param(n, "mode")) end},
    {label = "rate", param = function(n) return lfo_param(n, lfos().is_clocked(n) and "division" or "rate") end,
      value = rate_text},
    {label = "depth", whole = true, param = function(n) return lfo_param(n, "depth") end,
      value = function(n) return string.format("%.0f%%", params:get(lfo_param(n, "depth"))) end},
    {label = "offset", whole = true, param = function(n) return lfo_param(n, "offset") end,
      value = function(n) return signed(params:get(lfo_param(n, "offset"))) end},
    {label = "phase", whole = true, param = function(n) return lfo_param(n, "phase") end,
      value = function(n) return string.format("ph %.0f%%", params:get(lfo_param(n, "phase"))) end},
    {label = "rate mod", param = function(n) return lfo_param(n, "rate_mod") end,
      value = function(n) return "rmod " .. params:string(lfo_param(n, "rate_mod")) end},
    {label = "rate amt", whole = true, param = function(n) return lfo_param(n, "rate_mod_amt") end,
      value = function(n) return "ramt " .. signed(params:get(lfo_param(n, "rate_mod_amt"))) end},
    {label = "depth mod", param = function(n) return lfo_param(n, "depth_mod") end,
      value = function(n) return "dmod " .. params:string(lfo_param(n, "depth_mod")) end},
    {label = "depth amt", whole = true, param = function(n) return lfo_param(n, "depth_mod_amt") end,
      value = function(n) return "damt " .. signed(params:get(lfo_param(n, "depth_mod_amt"))) end},
    {label = "on/off", param = function(n) return lfo_param(n) end,
      value = function(n) return lfo_running(n) and "on" or "off" end},
  }
  local DEST_FIELD, RATE_FIELD, STATE_FIELD = 1, 4, #LFO_FIELDS

  -- Top of LFO n's row, or nil when it lies outside the window: the rows
  -- under the selected LFO's sit below its strip
  local function row_top(n)
    local first = lfos().window(S.selected_lfo)
    if n < first or n >= first + LFO_PAGE.window_rows then return nil end
    local top = LFO_PAGE.row_first_y + (n - first) * LFO_PAGE.row_spacing
    if n > S.selected_lfo then top = top + LFO_PAGE.strip_height end
    return top
  end
  M.row_top = row_top

  -- The strip's text baseline
  local function strip_y()
    return row_top(S.selected_lfo) + LFO_PAGE.strip_baseline
  end
  M.strip_y = strip_y

  -- The destination groups' first indices into S.LFO_DESTINATIONS: each
  -- index whose group (lib/lfos.lua: none, the globals, each voice's
  -- built-in ones, each per-voice registration's v1-v7, then every global
  -- registration as one group, #511, #580) differs from the one before it
  function lfo_dest_group_starts()
    local starts = {}
    local previous
    for index, destination in ipairs(S.LFO_DESTINATIONS) do
      if destination.group ~= previous then table.insert(starts, index) end
      previous = destination.group
    end
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

  -- Turn LFO n on or off, as a controller mapped to it sees (#538)
  local function set_lfo_running(n, on)
    set_binary_param(lfo_param(n), on and 1 or 0)
  end

  local function toggle_selected_lfo()
    set_lfo_running(S.selected_lfo, not lfo_running(S.selected_lfo))
  end

  -- The selected LFO: ring 4's carried ticks were for the old LFO's rate,
  -- and the depth rings' for the old window's LFOs
  local function select_lfo(n)
    local previous_lfo = S.selected_lfo
    local previous_window = lfos().window(previous_lfo)
    S.selected_lfo = util.clamp(n, 1, NUM_LFOS)
    if S.selected_lfo == previous_lfo then return end
    forget_arc_ticks("lfo:4")
    if lfos().window(S.selected_lfo) ~= previous_window then
      for ring = 1, LFO_PAGE.window_rows do forget_arc_ticks("lfo:" .. ring) end
    end
    request_redraw()
  end

  -- K2/K3: the previous or next LFO
  function M.select_lfo_by(d)
    select_lfo(S.selected_lfo + d)
  end

  -- The LFO page with LFO n selected (MOD's K3 on an LFO's row)
  function M.show_lfo(n)
    select_lfo(n)
    S.lib.ui_keys.set_ui_page(UI_PAGES.index.LFO)
  end

  -- One point (0..1) of a shape's drawing at a phase: the deterministic
  -- shapes as they play (lib/lfos.lua's shape_u), a random one as a
  -- picture of its kind
  function lfo_wave_value(shape, phase)
    local points = LFO_PAGE.random_displays[shape]
    if not points then
      for index, name in ipairs(S.lib.lfos.LFO.shapes) do
        if name == shape then return S.lib.lfos.shape_u(index, phase) end
      end
      return 0.5
    end
    for index = 2, #points do
      local from, to = points[index - 1], points[index]
      if phase <= to[1] and to[1] > from[1] then
        return from[2] + (to[2] - from[2]) * (phase - from[1]) / (to[1] - from[1])
      end
    end
    return points[#points][2]
  end

  -- Whether the matrix (package 1h) routes LFO n somewhere: read
  -- defensively, as the matrix may not be loaded
  local function routed(n)
    return S.lib.matrix ~= nil and S.lib.matrix.uses_source("lfo" .. n) and true or false
  end

  local function draw_lfo_row(n)
    local top = row_top(n)
    local bottom = top + LFO_PAGE.wave_height
    local running = lfo_running(n)
    local label_level = n == S.selected_lfo and 15 or 4

    screen.level(label_level)
    screen.move(0, top + 7)
    screen.text("L" .. n)

    local shape = params:string(lfo_param(n, "shape"))
    screen.level(running and 6 or 2)
    for px = 0, LFO_PAGE.wave_width - 1 do
      local y = bottom - lfo_wave_value(shape, px / (LFO_PAGE.wave_width - 1)) * LFO_PAGE.wave_height
      if px == 0 then
        screen.move(LFO_PAGE.wave_x, y)
      else
        screen.line(LFO_PAGE.wave_x + px, y)
      end
    end
    screen.stroke()

    if running and lfos().has_stepped(n) then
      local x = util.round(LFO_PAGE.wave_x + lfos().phase(n) * (LFO_PAGE.wave_width - 1))
      -- the swing around the middle line follows the depth it plays: the
      -- whole wave at 100 %, the line itself at 0 % (which moves nothing, #520)
      local swing = lfos().value(n) / 2 * lfos().effective_depth(n) / 100
      local y = util.round(bottom - (0.5 + swing) * LFO_PAGE.wave_height)
      screen.level(15)
      screen.rect(x - 1, y - 1, 3, 3)
      -- a free engine-run LFO's phase is Lua's estimate: drawn hollow
      if lfos().is_engine_run(n) and not lfos().is_clocked(n) then screen.stroke() else screen.fill() end
    end

    if n == lfos().window(S.selected_lfo) then
      screen.level(4)
      screen.move(LFO_PAGE.mark_x, top + 11)
      screen.text(n .. "-" .. (n + LFO_PAGE.window_rows - 1))
    end

    screen.level(label_level)
    -- 7 px above the state text, so a descender (the y of "density") clears
    -- it (#422), and 6 px under the row above's (LFO_PAGE.row_spacing)
    screen.move(127, top + 4)
    screen.text_right(lfos().label(n))
    screen.move(127, top + 11)
    screen.text_right((running and "on " or "off ") .. string.format("%.0f%%", params:get(lfo_param(n, "depth")))
      .. (routed(n) and " R" or ""))
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
    local first = lfos().window(S.selected_lfo)
    for n = first, first + LFO_PAGE.window_rows - 1 do
      draw_lfo_row(n)
    end
    draw_strip()
  end

  -- The hint row (redraw() draws it after the page). K1 let go while
  -- ALT+K2 is down: K2's hint alone, since its release still acts
  local function lfo_hints(alt_held)
    local record = S.registry.pages[UI_PAGES.index.LFO]
    if alt_held then
      -- on the destination, ALT+E3 jumps a group
      local jump = S.lfo_field == DEST_FIELD and " E3:group" or ""
      return S.lib.ui_alt.k2_hint(record) .. " K3:" .. (lfo_running(S.selected_lfo) and "off" or "on") .. jump
    end
    if S.lib.ui_alt.k2_held() then return S.lib.ui_alt.k2_hint(record) end
    return "K2/K3:lfo E3:" .. LFO_FIELDS[S.lfo_field].label
  end

  -- E2 moves along the strip; E3 edits the cursor's field of the selected
  -- LFO (ALT+E3 fine on a control param: the free rate)
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

  -- ALT+E3 on the destination jumps a group per detent (none, global,
  -- v1 ... v7, then each registered destination, then the registered
  -- globals); on a percent it keeps whole steps (a fine step of a whole
  -- percent would round back); anything else goes on to lfo_enc
  local function lfo_alt_enc(n, d)
    if n ~= 3 then return false end
    local field = LFO_FIELDS[S.lfo_field]
    if field.whole then
      delta_with_detent(field.param(S.selected_lfo), d)
      return true
    end
    if S.lfo_field ~= DEST_FIELD then return false end
    local dest_id = field.param(S.selected_lfo)
    local index = params:get(dest_id)
    for _ = 1, math.abs(d) do
      index = lfo_dest_group_jump(index, d)
    end
    params:set(dest_id, index)
    return true
  end

  local function lfo_key(n)
    if n == 2 then
      M.select_lfo_by(-1)
    elseif n == 3 then
      M.select_lfo_by(1)
    end
  end

  -- ALT+K2 acts on release (lfo_alt_key_release): the press notes its time.
  -- ALT+K3 turns the selected LFO on or off
  local function lfo_alt_key(n)
    if n == 2 then
      S.lib.ui_alt.k2_down()
    elseif n == 3 then
      toggle_selected_lfo()
    end
    request_redraw()
  end

  -- A quick ALT+K2 randomizes the selected LFO's shape (any of the eight),
  -- its rate (free: even in octaves over LFO_PAGE.free_random) or division
  -- (clocked: any), and its phase (a whole 0-100), and nothing else (#557):
  -- destination, mode, depth, offset, on/off and the four mod params are
  -- kept, so a running LFO keeps running. The section names the LFO and
  -- its mode ("lfo 2 free"), so each LFO holds its own undo and a mode
  -- switch drops the undo of the rate no longer shown; voice is nil, so no
  -- voice's mutation ends it
  local function lfo_randomize_section()
    local n = S.selected_lfo
    local mode = params:string(lfo_param(n, "mode"))
    local low, high = LFO_PAGE.free_random[1], LFO_PAGE.free_random[2]
    local draws = {
      {id = lfo_param(n, "shape"), draw = function() return math.random(#S.lib.lfos.LFO.shapes) end},
    }
    if mode == "clocked" then
      draws[2] = {id = lfo_param(n, "division"), draw = function() return math.random(#S.lib.lfos.LFO.divisions) end}
    else
      draws[2] = {id = lfo_param(n, "rate"), draw = function() return low * (high / low) ^ math.random() end}
    end
    draws[3] = {id = lfo_param(n, "phase"), draw = function() return math.random(0, 100) end}
    return {page = UI_PAGES.index.LFO, section = "lfo " .. n .. " " .. mode, voice = nil, draws = draws}
  end

  -- ALT+K2 held ALT_HOLD_SECONDS resets the cursor's field to its default
  local function lfo_alt_hold()
    local lfo = S.selected_lfo
    local param_id = LFO_FIELDS[S.lfo_field].param(lfo)
    if S.lfo_field == STATE_FIELD then
      set_lfo_running(lfo, param_default(param_id) == 1)
    else
      params:set(param_id, param_default(param_id))
    end
  end

  local function lfo_alt_key_release(n)
    if n == 2 then S.lib.ui_alt.k2_up(S.registry.pages[UI_PAGES.index.LFO]) end
  end

  -- The layout test's states: each strip field under the cursor on LFOs 1
  -- and 6 (with wide values), each window, an engine-run and modulated
  -- LFO, a rate with "max", clocked, and the widest ALT hint
  local function layout_state(name, lfo, field, setup)
    return {name = name, setup = function()
      S.selected_lfo = lfo
      S.lfo_field = field
      if setup then setup() end
    end}
  end
  -- The index of the option called name among a param's options, so a
  -- state keeps its meaning when the lists change
  local function option_named(param_id, name)
    for index, option in ipairs(params:lookup_param(param_id).options) do
      if option == name then return index end
    end
  end
  local function destination_labeled(label)
    for index, destination in ipairs(S.LFO_DESTINATIONS) do
      if destination.label == label then return index end
    end
  end
  -- LFO n at its widest: the last destination, a wide shape, the widest
  -- percents, its mod sources (LFO 1 has none)
  local function widest(n)
    params:set(lfo_param(n, "dest"), #S.LFO_DESTINATIONS)
    params:set(lfo_param(n, "shape"), option_named(lfo_param(n, "shape"), "smooth"))
    params:set(lfo_param(n, "rate"), 0.003)
    params:set(lfo_param(n, "depth"), 100)
    params:set(lfo_param(n, "offset"), -100)
    params:set(lfo_param(n, "phase"), 100)
    params:set(lfo_param(n, "rate_mod"), #params:lookup_param(lfo_param(n, "rate_mod")).options)
    params:set(lfo_param(n, "rate_mod_amt"), -100)
    params:set(lfo_param(n, "depth_mod"), #params:lookup_param(lfo_param(n, "depth_mod")).options)
    params:set(lfo_param(n, "depth_mod_amt"), -100)
    params:set(lfo_param(n), 1)
  end
  local layout_states = {}
  for _, n in ipairs({1, NUM_LFOS}) do
    for field, entry in ipairs(LFO_FIELDS) do
      table.insert(layout_states, layout_state("lfo" .. n .. " " .. entry.label, n, field, function() widest(n) end))
    end
  end
  for first = 1, NUM_LFOS - LFO_PAGE.window_rows + 1 do
    local selected = first == 1 and 1 or first + 1
    table.insert(layout_states, layout_state("window " .. first .. "-" .. (first + LFO_PAGE.window_rows - 1), selected,
      DEST_FIELD, function()
        for n = first, first + LFO_PAGE.window_rows - 1 do
          params:set(lfo_param(n, "dest"), destination_labeled(n % 2 == 0 and "density" or "v7 pitch"))
          params:set(lfo_param(n), 1)
        end
      end))
  end
  table.insert(layout_states, layout_state("engine-run and modulated", 3, DEST_FIELD, function()
    params:set(lfo_param(3, "dest"), destination_labeled("v7 pitch"))
    params:set(lfo_param(3, "rate_mod"), option_named(lfo_param(3, "rate_mod"), "L1"))
    params:set(lfo_param(3, "depth_mod"), option_named(lfo_param(3, "depth_mod"), "L2"))
    params:set(lfo_param(3, "depth"), 100)
    params:set(lfo_param(1), 1); params:set(lfo_param(3), 1)
  end))
  table.insert(layout_states, layout_state("rate max", 2, RATE_FIELD, function()
    params:set(lfo_param(2, "dest"), destination_labeled("dly fdbk"))
    params:set(lfo_param(2, "rate"), 12.5)
    params:set(lfo_param(2), 1)
  end))
  table.insert(layout_states, layout_state("clocked", 5, RATE_FIELD, function()
    params:set(lfo_param(5, "mode"), option_named(lfo_param(5, "mode"), "clocked"))
    params:set(lfo_param(5, "division"), option_named(lfo_param(5, "division"), "1/16"))
    params:set(lfo_param(5, "dest"), destination_labeled("rev damp"))
    params:set(lfo_param(5), 1)
  end))
  -- destinations whose labels have descenders over the state text (#422)
  for index, label in ipairs({"density", "v1 pos", "dly fdbk"}) do
    table.insert(layout_states, layout_state("descender " .. label, index, DEST_FIELD, function()
      params:set(lfo_param(index, "dest"), destination_labeled(label))
      params:set(lfo_param(index), 1)
    end))
  end
  -- ALT's widest hint: K2:reset K3:off E3:group (a running LFO, the cursor
  -- on its destination)
  table.insert(layout_states, {name = "ALT+K2 held past the hold time", setup = function(context)
    S.selected_lfo = 1
    S.lfo_field = DEST_FIELD
    params:set(lfo_param(1), 1)
    key(1, 1); key(2, 1)
    context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  end})

  -- Only a running LFO's dot moves, so the page draws every frame only
  -- while one runs (#423); every other change asks for a redraw (the param
  -- actions, enc, key, the rings), turning the last LFO off included
  -- (and while ALT+K2 is down, so its hint turns to K2:reset at the hold time)
  local function any_lfo_running()
    if S.lib.ui_alt.k2_held() then return true end
    for n = 1, NUM_LFOS do
      if lfo_running(n) then return true end
    end
    return false
  end

  -- The page's record, at LFO's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/lfo.lua's
  S.registry.pages[UI_PAGES.index.LFO] = {name = "LFO", draw = redraw_lfo, hints = lfo_hints,
    enc = lfo_enc, alt_enc = lfo_alt_enc, key = lfo_key, alt_key = lfo_alt_key,
    alt_key_release = lfo_alt_key_release, alt_hold = lfo_alt_hold, randomize_section = lfo_randomize_section,
    animates = any_lfo_running, arc_button = toggle_selected_lfo, layout_states = layout_states}

  return M
end

-- lib/pages/mod.lua
-- The MOD page (3.4, design §10 and §10.2): the modulation in one list,
-- under section labels in MOD_PAGE.sections' order (macros, morph,
-- scatter, gestures, lfos, matrix, then every section a later source
-- registers, in registration order). The macros, gestures and lfos rows,
-- and any registered section's, are the modulation sources
-- (S.lib.mod_sources), each drawn and edited through its record (name,
-- describe(), row); the bank row, the morph and scatter rows and the
-- matrix's routings R1-R16 are the page's own. K3 on a macro row opens its
-- target view, on a routing row the routing view; ALT+K3 there learns
-- (S.lib.macros.learn, S.lib.matrix.learn), canceled by K2 and a page
-- change. ALT+K2 on release randomizes the scatter or matrix section
-- (S.lib.ui_alt's shared handler, with its undo; held 0.5 s it clears a
-- recorder, a target row or a routing). The rows are built from the
-- registry at each use and the cursor follows its row's id, so a source
-- registered later shows at once and a bank change keeps the cursor's
-- place. Registers its S.registry.pages record. S.lib.pages_mod holds what
-- tests and the rings (lib/arc/mod.lua) read and move: place, view,
-- section, cursor_routing, routing, macro, target_row, target_bounds,
-- nudge_bound, move_target_row, step_source, step_dest, move_routing,
-- source_position, dest_position, routing_plays, carry_context.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local MATRIX_SLOTS = S.constants.MATRIX_SLOTS
  local MACRO_TARGETS = S.constants.MACRO_TARGETS
  local NUM_GESTURES = S.constants.NUM_GESTURES
  local FL = S.lib.ui_field_list

  -- The list: five rows from y 18, 8 px apart, section labels at x 0 (level
  -- 2), a row's label at x 6, its text from x 24 (or 4 px after a wider
  -- label), its value right-aligned at 124. A row that does not play (a
  -- routing off or incomplete) is dim. The two views: a title on y 16,
  -- rows from y 24, 7 px apart (five of the eight targets in view). The
  -- target bounds step 1 % (ALT+E3 0.1 %). The randomize ranges (#557,
  -- plan item 4): scatter's depth (whole percents) and rate (even in
  -- octaves), a complete routing's depth (whole percents)
  local MOD_PAGE = {
    sections = {"macros", "morph", "scatter", "gestures", "lfos", "matrix"},
    visible_rows = 5, first_row_y = 18, row_spacing = 8,
    label_x = 6, text_x = 24, value_right = 124, gap = 4,
    title_y = 16, view_first_y = 24, view_spacing = 7, view_label_x = 8,
    levels = {selected = 15, row = 8, dim_selected = 10, dim = 4, section = 2, part = 8},
    bound_step = 0.01, bound_fine_step = 0.001,
    columns = {"target", "min", "max"},
    routing_rows = {"source", "dest", "depth", "on"},
    random = {depth = {0, 30}, rate = {0.02, 0.5}, matrix = {-50, 50}},
  }
  S.MOD_PAGE = MOD_PAGE

  -- The cursor: the list row (an index and its id), the view ("list",
  -- "targets" or "routing"; views counts every change of it), the target
  -- view's macro, row and column, the routing view's routing and row
  S.mod_page = {row = nil, row_id = nil, view = "list", views = 0, macro = 1, target_row = 1, target_column = 1,
    routing = 1, routing_row = 1}

  local function page_record() return S.registry.pages[UI_PAGES.index.MOD] end
  local function depth_id(k) return "matrix_" .. k .. "_depth" end
  local function on_id(k) return "matrix_" .. k end
  local function percent(fraction) return string.format("%d%%", math.floor(fraction * 100 + 0.5)) end
  local function signed(value) return string.format(value > 0 and "+%.0f%%" or "%.0f%%", value) end
  local function on_text(param_id) return params:get(param_id) == 1 and "on" or "off" end

  ---------------------------------------------------------------------------
  -- The rows
  ---------------------------------------------------------------------------

  -- MOD's own rows per section: kind "bank", "param" (E3 the param, its
  -- value text and hint), "toggle" (a binary param, K3 and E3) or
  -- "routing" (routing k)
  local OWN_ROWS = {
    macros = {{id = "bank", label = "bank", kind = "bank"}},
    morph = {
      {id = "morph_a", label = "A", kind = "param", param_id = "morph_a", hint = "E3:scene",
        value = function() return S.lib.scenes.label(params:get("morph_a")) end},
      {id = "morph_b", label = "B", kind = "param", param_id = "morph_b", hint = "E3:scene",
        value = function() return S.lib.scenes.label(params:get("morph_b")) end},
      {id = "morph", label = "morph", kind = "param", param_id = "morph", hint = "E3:morph",
        value = function() return percent(params:get("morph")) end},
    },
    scatter = {
      {id = "scatter", label = "on", kind = "toggle", param_id = "scatter"},
      {id = "scatter_depth", label = "depth", kind = "param", param_id = "scatter_depth", hint = "E3:depth",
        value = function() return string.format("%.0f%%", params:get("scatter_depth")) end},
      {id = "scatter_rate", label = "rate", kind = "param", param_id = "scatter_rate", hint = "E3:rate",
        value = function() return string.format("%.2f Hz", params:get("scatter_rate")) end},
    },
    matrix = {},
  }
  for _, destination in ipairs(S.lib.scatter.SCATTER.destinations) do
    table.insert(OWN_ROWS.scatter, {id = destination.id, label = destination.id:match("^scatter_(.+)$"),
      kind = "toggle", param_id = destination.id})
  end
  for k = 1, MATRIX_SLOTS do
    OWN_ROWS.matrix[k] = {id = "routing:" .. k, label = "R" .. k, kind = "routing", k = k}
  end
  for section, rows in pairs(OWN_ROWS) do
    for _, row in ipairs(rows) do row.section = section end
  end

  -- MOD_PAGE.sections, then every other section a source registered, in
  -- the order its first source did
  local function section_order()
    local order, seen = {}, {}
    for _, name in ipairs(MOD_PAGE.sections) do
      order[#order + 1] = name
      seen[name] = true
    end
    for _, name in ipairs(S.lib.mod_sources.sections()) do
      if not seen[name] then
        order[#order + 1] = name
        seen[name] = true
      end
    end
    return order
  end

  -- Every row, built from the registry now: per section with any row, its
  -- label (no cursor stop), MOD's own rows, then its visible sources
  local function build_rows()
    local rows = {}
    for _, section in ipairs(section_order()) do
      local own = OWN_ROWS[section] or {}
      local sources = S.lib.mod_sources.list(section)
      if #own + #sources > 0 then
        rows[#rows + 1] = {id = "section:" .. section, label = section, selectable = false, section = section}
        for _, row in ipairs(own) do rows[#rows + 1] = row end
        for _, record in ipairs(sources) do
          rows[#rows + 1] = {id = "source:" .. record.key, label = record.name, kind = "source", source = record,
            section = section}
        end
      end
    end
    return rows
  end

  -- The rows and the list cursor's index: the row with the cursor's id
  -- where it is, else the same index (a bank change: the same row of the
  -- new bank), always a selectable row
  local function list_cursor()
    local rows = build_rows()
    local state = S.mod_page
    local index = state.row
    if not (type(index) == "number" and rows[index] and rows[index].id == state.row_id) then
      for position, row in ipairs(rows) do
        if row.id == state.row_id then
          index = position
          break
        end
      end
    end
    index = FL.clamp(rows, index)
    state.row, state.row_id = index, rows[index].id
    return rows, index
  end

  local function cursor_row()
    local rows, index = list_cursor()
    return rows[index]
  end

  local function set_cursor(rows, index)
    S.mod_page.row, S.mod_page.row_id = index, rows[index].id
  end

  -- Put the list cursor on the row with this id ("bank", "morph",
  -- "scatter_rate", "routing:3", "source:macro5", ...). Returns whether
  -- the row exists now
  function M.place(id)
    local rows = build_rows()
    for index, row in ipairs(rows) do
      if row.id == id and row.selectable ~= false then
        set_cursor(rows, index)
        request_redraw()
        return true
      end
    end
    return false
  end

  -- The macro a row is (the source macro<m>), or nil
  local function row_macro(row)
    if not (row and row.kind == "source") then return nil end
    return tonumber(row.source.key:match("^macro(%d+)$"))
  end

  -- K2: the next section's first row, after the last the first
  local function next_section()
    local rows, index = list_cursor()
    local section = rows[index].section
    for position = index + 1, #rows do
      if rows[position].selectable ~= false and rows[position].section ~= section then
        set_cursor(rows, position)
        return
      end
    end
    set_cursor(rows, FL.clamp(rows, 1))
  end

  ---------------------------------------------------------------------------
  -- Sources, destinations and targets as lists (the views' E3, the rings)
  ---------------------------------------------------------------------------

  -- The LFO destinations' labels and groups by id (a voice's main entry as
  -- v<i>_main), the matrix's destinations and the macros' targets (a set),
  -- rebuilt when params are added
  local catalog = {count = nil}
  local function destinations()
    if catalog.count == #params.params then return catalog end
    local labels, groups, index = {}, {}, {}
    for _, entry in ipairs(S.LFO_DESTINATIONS) do
      local voice = entry.label:match("^v(%d+) main$")
      local id = voice and ("v" .. voice .. "_main") or entry.resolve()
      if id and labels[id] == nil then
        labels[id] = entry.label
        groups[id] = entry.group
      end
    end
    local ids, targets = S.lib.matrix.destination_ids(), {}
    for position, id in ipairs(ids) do index[id] = position end
    for _, id in ipairs(S.lib.macros.target_ids()) do targets[id] = true end
    catalog = {count = #params.params, labels = labels, groups = groups, ids = ids, index = index, targets = targets}
    return catalog
  end

  -- A destination as a routing shows it: its label, with ~ when it runs in
  -- the engine (a voice's main entry as it resolves now); "-" for none; an
  -- id this build lacks as stored. Second: whether it is known
  local function dest_text(id)
    if id == "" then return "-", false end
    local known = destinations()
    if not known.index[id] then return id, false end
    local resolved = id
    local voice = id:match("^v(%d+)_main$")
    if voice then resolved = main_param_id(tonumber(voice)) end
    return (known.labels[id] or id) .. (S.lib.lfos.fast_destination(resolved) and "~" or ""), true
  end

  -- A source as a routing shows it: its name; "-" for none; a key this
  -- build lacks as stored. Second: whether it is known
  local function source_text(key)
    if key == "" then return "-", false end
    local record = S.lib.mod_sources.get(key)
    if not record then return key, false end
    return record.name, true
  end

  -- Whether routing k holds a known source and destination, and whether it
  -- plays as MOD draws it (complete and on; a depth of 0 still shows)
  local function routing_complete(k)
    local routing = S.lib.matrix.routing(k)
    local _, source_known = source_text(routing.source)
    local _, dest_known = dest_text(routing.dest)
    return source_known and dest_known, routing
  end

  function M.routing_plays(k)
    local complete, routing = routing_complete(k)
    return complete and routing.on
  end

  -- From index, d whole steps along a list, clamped
  local function step_index(index, d, count)
    return util.clamp(index + d, 1, count)
  end

  -- From index, |d| group starts on (d > 0) or back (d < 0): groups[i] is
  -- entry i's group, and a group starts where it differs from the entry
  -- before (as the LFO page's destination jump)
  local function group_jump(groups, index, d)
    local starts = {}
    for position, group in ipairs(groups) do
      if position == 1 or group ~= groups[position - 1] then starts[#starts + 1] = position end
    end
    for _ = 1, math.abs(d) do
      local found = index
      if d > 0 then
        for _, start in ipairs(starts) do
          if start > index then found = start; break end
        end
      else
        for position = #starts, 1, -1 do
          if starts[position] < index then found = starts[position]; break end
        end
      end
      index = found
    end
    return index
  end

  -- A list's entries ("" first, for none) and each one's group
  local function source_choices()
    local keys, groups = {""}, {"none"}
    for _, record in ipairs(S.lib.mod_sources.list()) do
      keys[#keys + 1] = record.key
      groups[#groups + 1] = record.section
    end
    return keys, groups
  end

  local function dest_choices()
    local known = destinations()
    local ids, groups = {""}, {"none"}
    for _, id in ipairs(known.ids) do
      ids[#ids + 1] = id
      groups[#groups + 1] = known.groups[id] or id
    end
    return ids, groups
  end

  -- A macro target's group: its LFO destination's, an LFO's rate or depth,
  -- or a routing's depth
  local function target_choices()
    local known = destinations()
    local ids, groups = {""}, {"none"}
    for _, id in ipairs(S.lib.macros.target_ids()) do
      ids[#ids + 1] = id
      groups[#groups + 1] = known.groups[id] or (id:match("^strata_lfo") and "lfo params") or "matrix depths"
    end
    return ids, groups
  end

  local function position_of(list, value)
    for index, entry in ipairs(list) do
      if entry == value then return index end
    end
    return 1  -- unknown or not shown: from none
  end

  -- d steps (ALT: d groups) from value along list
  local function choose(list, groups, value, d)
    local index = position_of(list, value)
    if S.alt_held then return list[group_jump(groups, index, d)] end
    return list[step_index(index, d, #list)]
  end

  ---------------------------------------------------------------------------
  -- Actions
  ---------------------------------------------------------------------------

  local function show_bank(bank)
    if bank ~= S.lib.macros.bank() then S.lib.macros.set_bank(bank) end
  end

  -- The bank after (d > 0) or before (d < 0) the shown one, wrapping
  local function wrap_bank(d)
    local banks = S.lib.macros.MACROS.banks
    show_bank((S.lib.macros.bank() - 1 + d) % banks + 1)
  end

  local function set_toggle(param_id, value)
    if params:get(param_id) ~= value then set_binary_param(param_id, value) end
  end

  local function toggle(param_id) set_binary_param(param_id, 1 - params:get(param_id)) end

  local function change_view(view)
    local state = S.mod_page
    state.view = view
    state.views = state.views + 1
    request_redraw()
  end

  local function open_targets(m)
    S.mod_page.macro, S.mod_page.target_row, S.mod_page.target_column = m, 1, 1
    change_view("targets")
  end

  local function open_routing(k)
    S.mod_page.routing, S.mod_page.routing_row = k, 1
    change_view("routing")
  end

  -- Back to the list (K2), learn canceled, the cursor on the row the view
  -- was opened from where it shows
  local function close_view()
    local state = S.mod_page
    S.lib.macros.cancel_learn()
    S.lib.matrix.cancel_learn()
    local id = state.view == "targets" and ("source:macro" .. state.macro) or ("routing:" .. state.routing)
    change_view("list")
    M.place(id)
  end

  -- K3 on a list row
  local function press(row)
    if row.kind == "bank" then
      wrap_bank(1)
    elseif row.kind == "toggle" then
      toggle(row.param_id)
    elseif row.kind == "routing" then
      open_routing(row.k)
    elseif row.kind == "source" then
      local m = row_macro(row)
      if m then
        open_targets(m)
      elseif row.source.row and row.source.row.press then
        row.source.row.press()
      end
    end
  end

  -- E3 on a list row (ALT+E3 fine on a control param or a source's fine_enc)
  local function list_enc(row, d)
    if row.kind == "bank" then
      show_bank(util.clamp(S.lib.macros.bank() + d, 1, S.lib.macros.MACROS.banks))
    elseif row.kind == "param" then
      enc_param_delta(3, row.param_id, d)
    elseif row.kind == "toggle" then
      set_toggle(row.param_id, d > 0 and 1 or 0)
    elseif row.kind == "routing" then
      enc_param_delta(3, depth_id(row.k), d)
    elseif row.kind == "source" and row.source.row then
      local actions = row.source.row
      local turn = (S.alt_held and actions.fine_enc) or actions.enc
      if turn then turn(d) end
    end
  end

  -- The target view's row: a copy of {id, min, max}
  local function target()
    local state = S.mod_page
    return S.lib.macros.targets(state.macro)[state.target_row]
  end

  -- Set the cursor row's min or max (which) to value, clamped to 0..1; an
  -- empty row has none
  local function set_bound(which, value)
    local state, row = S.mod_page, target()
    if row.id == "" then return end
    row[which] = util.clamp(value, 0, 1)
    S.lib.macros.set_target(state.macro, state.target_row, row.id, row.min, row.max)
  end

  local function targets_enc(n, d)
    local state = S.mod_page
    if n == 2 then
      state.target_row = util.clamp(state.target_row + d, 1, MACRO_TARGETS)
      return
    end
    local row = target()
    local column = MOD_PAGE.columns[state.target_column]
    if column == "target" then
      local ids, groups = target_choices()
      local id = choose(ids, groups, row.id, d)
      if id ~= row.id then S.lib.macros.set_target(state.macro, state.target_row, id, row.min, row.max) end
    else
      local step = S.alt_held and MOD_PAGE.bound_fine_step or MOD_PAGE.bound_step
      set_bound(column, util.round(row[column] + d * step, MOD_PAGE.bound_fine_step))
    end
  end

  -- The routing view's source and destination, through edit_routing (MOD's
  -- 25 % rule for a routing it completes)
  local function edit_source(k, key) S.lib.matrix.edit_routing(k, key, S.lib.matrix.routing(k).dest) end
  local function edit_dest(k, id) S.lib.matrix.edit_routing(k, S.lib.matrix.routing(k).source, id) end

  local function routing_enc(n, d)
    local state = S.mod_page
    local k = state.routing
    if n == 2 then
      state.routing_row = util.clamp(state.routing_row + d, 1, #MOD_PAGE.routing_rows)
      return
    end
    local row = MOD_PAGE.routing_rows[state.routing_row]
    local routing = S.lib.matrix.routing(k)
    if row == "source" then
      local keys, groups = source_choices()
      edit_source(k, choose(keys, groups, routing.source, d))
    elseif row == "dest" then
      local ids, groups = dest_choices()
      edit_dest(k, choose(ids, groups, routing.dest, d))
    elseif row == "depth" then
      enc_param_delta(3, depth_id(k), d)
    else
      set_toggle(on_id(k), d > 0 and 1 or 0)
    end
  end

  local function mod_enc(n, d)
    local view = S.mod_page.view
    if view == "targets" then
      targets_enc(n, d)
    elseif view == "routing" then
      routing_enc(n, d)
    elseif n == 2 then
      local rows, index = list_cursor()
      set_cursor(rows, FL.move(rows, index, d))
    elseif n == 3 then
      list_enc(cursor_row(), d)
    end
  end

  -- ALT+E2 on a macro row: the same row of the next bank (4 wraps to 1),
  -- or of the one before; anything else goes on to mod_enc
  local function mod_alt_enc(n, d)
    if n ~= 2 or S.mod_page.view ~= "list" or not row_macro(cursor_row()) then return false end
    wrap_bank(d > 0 and 1 or -1)
    return true
  end

  local function mod_key(n)
    local state = S.mod_page
    if state.view ~= "list" then
      if n == 2 then
        close_view()
      elseif n == 3 and state.view == "targets" then
        state.target_column = state.target_column % #MOD_PAGE.columns + 1
      elseif n == 3 then
        toggle(on_id(state.routing))
      end
    elseif n == 2 then
      next_section()
    elseif n == 3 then
      press(cursor_row())
    end
  end

  -- ALT+K2 acts on release (S.lib.ui_alt); ALT+K3: learn in a view (the
  -- target row, the routing's dest row), a routing's on/off and a source's
  -- alt_press(3) in the list
  local function mod_alt_key(n)
    local state = S.mod_page
    if n == 2 then
      S.lib.ui_alt.k2_down()
    elseif n == 3 then
      if state.view == "targets" then
        S.lib.macros.learn(state.macro, state.target_row)
      elseif state.view == "routing" then
        if MOD_PAGE.routing_rows[state.routing_row] == "dest" then S.lib.matrix.learn(state.routing) end
      else
        local row = cursor_row()
        if row.kind == "routing" then
          toggle(on_id(row.k))
        elseif row.kind == "source" and row.source.row and row.source.row.alt_press then
          row.source.row.alt_press(3)
        end
      end
    end
    request_redraw()
  end

  local function mod_alt_key_release(n)
    if n == 2 then S.lib.ui_alt.k2_up(page_record()) end
  end

  -- ALT+K2 held 0.5 s: what clears under the cursor (a target row with an
  -- id, a routing, a source's alt_press(2): a recorder), or nil
  local function hold_action()
    local state = S.mod_page
    if state.view == "targets" then
      if target().id == "" then return nil end
      return function() S.lib.macros.set_target(state.macro, state.target_row, "") end
    elseif state.view == "routing" then
      return function() S.lib.matrix.clear(state.routing) end
    end
    local row = cursor_row()
    if row.kind == "routing" then return function() S.lib.matrix.clear(row.k) end end
    if row.kind == "source" and row.source.row and row.source.row.alt_press then
      return function() row.source.row.alt_press(2) end
    end
    return nil
  end

  local function mod_alt_hold()
    local action = hold_action()
    if action then action() end
  end

  -- The held hint: K2:clear where the hold clears, K2:cancel elsewhere
  local function mod_alt_hold_hint()
    return hold_action() and "clear" or "cancel"
  end

  -- The section ALT+K2 randomizes (#557, plan item 4): scatter's depth and
  -- rate; the matrix's complete routings' depths; nil for the macros, the
  -- morph, the recorders and the LFOs (a macro apply writes up to eight
  -- params the undo would not hold). A view follows its section
  local SCATTER_SPEC = {page = UI_PAGES.index.MOD, section = "scatter", voice = nil, draws = {
    {id = "scatter_depth", draw = function() return math.random(MOD_PAGE.random.depth[1], MOD_PAGE.random.depth[2]) end},
    {id = "scatter_rate", draw = function()
      local low, high = MOD_PAGE.random.rate[1], MOD_PAGE.random.rate[2]
      return low * (high / low) ^ math.random()
    end},
  }}

  local function matrix_spec()
    local draws = {}
    for k = 1, MATRIX_SLOTS do
      if routing_complete(k) then
        draws[#draws + 1] = {id = depth_id(k), draw = function()
          return math.random(MOD_PAGE.random.matrix[1], MOD_PAGE.random.matrix[2])
        end}
      end
    end
    if #draws == 0 then return nil end
    return {page = UI_PAGES.index.MOD, section = "matrix", voice = nil, draws = draws}
  end

  local function mod_randomize_section()
    local view = S.mod_page.view
    if view == "routing" then return matrix_spec() end
    if view == "targets" then return nil end
    local section = cursor_row().section
    if section == "scatter" then return SCATTER_SPEC end
    if section == "matrix" then return matrix_spec() end
    return nil
  end

  -- The arc button: the routing's on/off in the matrix section and the
  -- routing view, the next bank on a macro or bank row, a gesture row's
  -- press, else scatter on/off
  local function mod_arc_button()
    local state = S.mod_page
    if state.view == "routing" then
      toggle(on_id(state.routing))
      return
    end
    if state.view == "list" then
      local row = cursor_row()
      if row.kind == "routing" then
        toggle(on_id(row.k))
        return
      elseif row.kind == "bank" or row_macro(row) then
        wrap_bank(1)
        return
      elseif row.kind == "source" and row.section == "gestures" and row.source.row and row.source.row.press then
        row.source.row.press()
        return
      end
    end
    toggle("scatter")
  end

  ---------------------------------------------------------------------------
  -- Drawing
  ---------------------------------------------------------------------------

  local L = MOD_PAGE.levels

  local function draw_text(x, y, text, level, right)
    screen.level(level)
    screen.move(x, y)
    if right then screen.text_right(text) else screen.text(text) end
  end

  -- A list row's label, text (left), value (right) and whether it is dim
  local function row_parts(row)
    if row.kind == "bank" then
      local macros = S.lib.macros.bank_macros(S.lib.macros.bank())
      return row.label, nil, S.lib.macros.bank() .. "  M" .. macros[1] .. "-M" .. macros[#macros], false
    elseif row.kind == "param" then
      return row.label, nil, row.value(), false
    elseif row.kind == "toggle" then
      return row.label, nil, on_text(row.param_id), false
    elseif row.kind == "routing" then
      local complete, routing = routing_complete(row.k)
      local dim = not (complete and routing.on)
      if routing.source == "" and routing.dest == "" then return row.label, "-", nil, dim end
      local text = source_text(routing.source) .. ">" .. dest_text(routing.dest)
      return row.label, text, signed(routing.depth), dim
    end
    local record = row.source
    local text = record.describe and record.describe() or ""
    local value = row_macro(row) and percent(S.lib.mod_sources.fraction(record.key)) or nil
    return row.label, text, value, false
  end

  local function draw_list_row(row, y, selected, value_right)
    if row.selectable == false then
      draw_text(0, y, S.lib.ui_text.fit_text(S.lib.ui_text.printable(row.label), value_right), L.section)
      return
    end
    local label, text, value, dim = row_parts(row)
    local level = dim and (selected and L.dim_selected or L.dim) or (selected and L.selected or L.row)
    label = S.lib.ui_text.printable(label)
    draw_text(MOD_PAGE.label_x, y, label, level)
    local right = value_right
    if value and value ~= "" then
      local room = value_right - MOD_PAGE.label_x - screen.text_extents(label) - MOD_PAGE.gap
      value = S.lib.ui_text.fit_text(S.lib.ui_text.printable(value), room)
      draw_text(value_right, y, value, level, true)
      right = value_right - screen.text_extents(value) - MOD_PAGE.gap
    end
    if text and text ~= "" then
      local x = math.max(MOD_PAGE.text_x, MOD_PAGE.label_x + screen.text_extents(label) + MOD_PAGE.gap)
      text = S.lib.ui_text.fit_text(S.lib.ui_text.printable(text), right - x)
      if text ~= "" then draw_text(x, y, text, level) end
    end
  end

  -- A target's bound as the row shows it: whole percents, a tenth where
  -- it has one
  local function bound_text(fraction)
    local tenths = math.floor(fraction * 1000 + 0.5)
    if tenths % 10 == 0 then return string.format("%d", math.floor(tenths / 10)) end
    return string.format("%.1f", tenths / 10)
  end

  -- One target row: its number, the target (its label; "-" when empty; an
  -- id this build lacks as stored, dim; "learn" while learn waits for it)
  -- and min>max%, the cursor's column bright on the cursor's row
  local TARGET_ROWS = {}
  for k = 1, MACRO_TARGETS do TARGET_ROWS[k] = {index = k} end

  local function draw_target_row(view_row, y, selected, value_right)
    local state = S.mod_page
    local row = S.lib.macros.targets(state.macro)[view_row.index]
    local function level_of(column)
      if not selected then return L.dim end
      return MOD_PAGE.columns[state.target_column] == column and L.selected or L.part
    end
    draw_text(0, y, tostring(view_row.index), selected and L.selected or L.dim)
    local learn_m, learn_k = S.lib.macros.learning()
    local label, label_level = "-", level_of("target")
    local right = value_right
    if row.id ~= "" then
      local max_text = bound_text(row.max) .. "%"
      local min_text = bound_text(row.min)
      draw_text(right, y, max_text, level_of("max"), true)
      right = right - screen.text_extents(max_text)
      draw_text(right, y, ">", selected and L.part or L.dim, true)
      right = right - screen.text_extents(">")
      draw_text(right, y, min_text, level_of("min"), true)
      right = right - screen.text_extents(min_text) - MOD_PAGE.gap
      label = S.lib.macros.target_label(row.id)
      if not destinations().targets[row.id] and label_level ~= L.selected then label_level = L.dim end
    end
    if learn_m == state.macro and learn_k == view_row.index then label, label_level = "learn", L.selected end
    label = S.lib.ui_text.fit_text(S.lib.ui_text.printable(label), right - MOD_PAGE.view_label_x)
    if label ~= "" then draw_text(MOD_PAGE.view_label_x, y, label, label_level) end
  end

  local function draw_targets()
    local state = S.mod_page
    state.target_row = util.clamp(state.target_row, 1, MACRO_TARGETS)
    draw_text(0, MOD_PAGE.title_y, "M" .. state.macro .. " targets", L.selected)
    draw_text(MOD_PAGE.value_right, MOD_PAGE.title_y, percent(params:get("macro_" .. state.macro)), L.part, true)
    FL.draw(TARGET_ROWS, state.target_row, {visible = MOD_PAGE.visible_rows, first_y = MOD_PAGE.view_first_y,
      spacing = MOD_PAGE.view_spacing}, draw_target_row)
  end

  -- The routing view's rows: source, dest, depth, on
  local ROUTING_VIEW_ROWS = {}
  for index, label in ipairs(MOD_PAGE.routing_rows) do ROUTING_VIEW_ROWS[index] = {index = index, label = label} end

  local function routing_value(name, k)
    local routing = S.lib.matrix.routing(k)
    if name == "source" then return source_text(routing.source) end
    if name == "dest" then
      if S.lib.matrix.learning() == k then return "learn", true end
      return dest_text(routing.dest)
    end
    if name == "depth" then return signed(routing.depth), true end
    return routing.on and "on" or "off", true
  end

  local function draw_routing_row(view_row, y, selected, value_right)
    local k = S.mod_page.routing
    local level = selected and L.selected or L.dim
    draw_text(0, y, view_row.label, level)
    local value = routing_value(view_row.label, k)
    local room = value_right - screen.text_extents(view_row.label) - MOD_PAGE.gap
    value = S.lib.ui_text.fit_text(S.lib.ui_text.printable(value), room)
    draw_text(value_right, y, value, level, true)
  end

  local function draw_routing()
    local state = S.mod_page
    state.routing = util.clamp(state.routing, 1, MATRIX_SLOTS)
    state.routing_row = util.clamp(state.routing_row, 1, #MOD_PAGE.routing_rows)
    draw_text(0, MOD_PAGE.title_y, "R" .. state.routing .. " routing", L.selected)
    draw_text(MOD_PAGE.value_right, MOD_PAGE.title_y, on_text(on_id(state.routing)), L.part, true)
    FL.draw(ROUTING_VIEW_ROWS, state.routing_row, {visible = MOD_PAGE.visible_rows, first_y = MOD_PAGE.view_first_y,
      spacing = MOD_PAGE.view_spacing}, draw_routing_row)
  end

  local function redraw_mod()
    local view = S.mod_page.view
    if view == "targets" then
      draw_targets()
    elseif view == "routing" then
      draw_routing()
    else
      local rows, index = list_cursor()
      FL.draw(rows, index, {visible = MOD_PAGE.visible_rows, first_y = MOD_PAGE.first_row_y,
        spacing = MOD_PAGE.row_spacing, value_right = MOD_PAGE.value_right}, draw_list_row)
    end
  end

  ---------------------------------------------------------------------------
  -- Hints
  ---------------------------------------------------------------------------

  -- Whether ALT+E3 on a list row is fine: a control param, a routing's
  -- depth, a source with fine_enc
  local function turns_finely(row)
    if row.kind == "param" then return params:lookup_param(row.param_id).controlspec ~= nil end
    if row.kind == "routing" then return true end
    return row.kind == "source" and row.source.row ~= nil and row.source.row.fine_enc ~= nil
  end

  local function list_hint(row)
    if row.kind == "bank" then return "K3:bank E3:bank" end
    if row.kind == "param" then return row.hint end
    if row.kind == "toggle" then return "K3:" .. (params:get(row.param_id) == 1 and "off" or "on") .. " E3:on/off" end
    if row.kind == "routing" then return "K3:edit E3:depth" end
    local actions = row.source.row
    if actions and actions.hints then return actions.hints(false) or "" end
    return ""
  end

  -- With ALT: K2's hint, then ALT+K3's (a routing's on/off, a source's
  -- own when it has alt_press), E2:bank on a macro row, E3:fine
  local function list_alt_hint(row)
    local parts = {S.lib.ui_alt.k2_hint(page_record())}
    if row.kind == "routing" then
      parts[#parts + 1] = "K3:" .. (params:get(on_id(row.k)) == 1 and "off" or "on")
    elseif row.kind == "source" and row.source.row and row.source.row.alt_press and row.source.row.hints then
      local own = row.source.row.hints(true) or ""
      if own ~= "" then parts[#parts + 1] = own end
    end
    if row_macro(row) then parts[#parts + 1] = "E2:bank" end
    if turns_finely(row) then parts[#parts + 1] = "E3:fine" end
    return table.concat(parts, " ")
  end

  local function view_hint(alt_held)
    local state = S.mod_page
    local record = page_record()
    if state.view == "targets" then
      local column = MOD_PAGE.columns[state.target_column]
      if alt_held then
        return S.lib.ui_alt.k2_hint(record) .. " K3:learn " .. (column == "target" and "E3:group" or "E3:fine")
      end
      return "K2:back K3:col E3:" .. column
    end
    local row = MOD_PAGE.routing_rows[state.routing_row]
    if alt_held then
      local extra = {dest = " K3:learn E3:group", source = " E3:section", depth = " E3:fine"}
      return S.lib.ui_alt.k2_hint(record) .. (extra[row] or "")
    end
    return "K2:back K3:" .. (params:get(on_id(state.routing)) == 1 and "off" or "on") .. " E3:" .. row
  end

  -- The hint row (redraw() draws it). K1 let go while ALT+K2 is down: K2's
  -- hint alone, since its release still acts
  local function mod_hints(alt_held)
    if not alt_held and S.lib.ui_alt.k2_held() then return S.lib.ui_alt.k2_hint(page_record()) end
    if S.mod_page.view ~= "list" then return view_hint(alt_held) end
    local row = cursor_row()
    if alt_held then return list_alt_hint(row) end
    return list_hint(row)
  end

  -- The frame clock redraws MOD every frame while ALT+K2 is down (its hint
  -- turns at the hold time), while a recorder records (its row counts the
  -- seconds) and while a row of a section MOD does not know is in view (a
  -- live value: the input level)
  local function mod_animates()
    if S.lib.ui_alt.k2_held() then return true end
    for k = 1, NUM_GESTURES do
      if S.lib.gestures.state(k) == "recording" then return true end
    end
    if S.mod_page.view ~= "list" then return false end
    local known = {}
    for _, name in ipairs(MOD_PAGE.sections) do known[name] = true end
    local rows, index = list_cursor()
    local first = FL.first_visible(rows, index, MOD_PAGE.visible_rows)
    for position = first, math.min(first + MOD_PAGE.visible_rows - 1, #rows) do
      if not known[rows[position].section] then return true end
    end
    return false
  end

  -- Leaving MOD cancels learn
  local function mod_leave()
    S.lib.macros.cancel_learn()
    S.lib.matrix.cancel_learn()
  end

  ---------------------------------------------------------------------------
  -- What the rings read and move (lib/arc/mod.lua)
  ---------------------------------------------------------------------------

  function M.view() return S.mod_page.view end
  function M.macro() return S.mod_page.macro end
  function M.target_row() return S.mod_page.target_row end
  function M.routing() return S.mod_page.routing end

  -- The cursor's section: its row's in the list, the view's own otherwise
  function M.section()
    local view = S.mod_page.view
    if view == "targets" then return "macros" end
    if view == "routing" then return "matrix" end
    return cursor_row().section
  end

  -- The routing under the list cursor, or nil
  function M.cursor_routing()
    if S.mod_page.view ~= "list" then return nil end
    local row = cursor_row()
    return row.kind == "routing" and row.k or nil
  end

  -- The target view's row: its min and max, and whether it has a target
  function M.target_bounds()
    local row = target()
    return row.min, row.max, row.id ~= ""
  end

  -- Ring 1 and 2 of the target view: move the row's min or max by amount
  -- (a fraction of 0..1)
  function M.nudge_bound(which, amount)
    local row = target()
    set_bound(which, row[which] + amount)
  end

  function M.move_target_row(steps)
    local state = S.mod_page
    state.target_row = util.clamp(state.target_row + steps, 1, MACRO_TARGETS)
  end

  function M.move_routing(steps)
    local state = S.mod_page
    state.routing = util.clamp(state.routing + steps, 1, MATRIX_SLOTS)
  end

  function M.step_source(steps)
    local k = S.mod_page.routing
    local keys = source_choices()
    edit_source(k, keys[step_index(position_of(keys, S.lib.matrix.routing(k).source), steps, #keys)])
  end

  function M.step_dest(steps)
    local k = S.mod_page.routing
    local ids = dest_choices()
    edit_dest(k, ids[step_index(position_of(ids, S.lib.matrix.routing(k).dest), steps, #ids)])
  end

  -- The routing view's source and destination as positions (0..1) along
  -- their lists (none first)
  function M.source_position()
    local keys = source_choices()
    return (position_of(keys, S.lib.matrix.routing(S.mod_page.routing).source) - 1) / math.max(#keys - 1, 1)
  end

  function M.dest_position()
    local ids = dest_choices()
    return (position_of(ids, S.lib.matrix.routing(S.mod_page.routing).dest) - 1) / math.max(#ids - 1, 1)
  end

  -- What the rings' carried ticks belong to: the view (and each opening of
  -- one), the section, the shown bank, the macro, and the routing unless
  -- with_routing is false (ring 4 of the routing view steps the routing
  -- itself)
  function M.carry_context(with_routing)
    local state = S.mod_page
    local parts = {state.view, state.views, M.section(), S.lib.macros.bank(), state.macro}
    if with_routing ~= false then parts[#parts + 1] = state.routing end
    return table.concat(parts, "|")
  end

  ---------------------------------------------------------------------------
  -- Layout states (the layout tests and the page renders)
  ---------------------------------------------------------------------------

  -- The widest of a list of texts, as norns' font draws them
  local function widest(texts)
    local best, best_width = texts[1], -1
    for _, text in ipairs(texts) do
      local width = screen.text_extents(text)
      if width > best_width then best, best_width = text, width end
    end
    return best
  end

  -- Every macro full, its eight targets the widest label at 99.9>99.9%
  local function widest_targets()
    local ids, labels = S.lib.macros.target_ids(), {}
    for index, id in ipairs(ids) do labels[index] = S.lib.macros.target_label(id) end
    local label = widest(labels)
    local id
    for index, each in ipairs(ids) do
      if labels[index] == label then id = id or each end
    end
    for m = 1, S.constants.NUM_MACROS do
      for k = 1, MACRO_TARGETS do S.lib.macros.set_target(m, k, id, 0.999, 0.999) end
      S.lib.macros.set_silently(m, 1)
    end
  end

  -- Every routing from M16 to the widest destination at -100 %
  local function widest_routings()
    local ids, texts = destinations().ids, {}
    for index, id in ipairs(ids) do texts[index] = dest_text(id) end
    local text = widest(texts)
    for index, id in ipairs(ids) do
      if texts[index] == text then
        for k = 1, MATRIX_SLOTS do
          S.lib.matrix.set_routing(k, "macro16", id)
          params:set(depth_id(k), -100)
        end
        return
      end
    end
  end

  local function hand_edit() delta_with_detent("reverb_mix", 1) end

  -- G1 empty, G2 playing, G3 stopped, G4 recording
  local function every_recorder_state(context)
    local gestures = S.lib.gestures
    for _, k in ipairs({2, 3}) do
      gestures.press(k); hand_edit(); context.clock.run_for(1.5); gestures.press(k)
    end
    gestures.press(3)
    gestures.press(4); hand_edit(); context.clock.run_for(12.3)
  end

  -- Six LFOs on v7's fast destinations, each following the LFOs before it
  local function engine_lfos()
    local labels = {"v7 pitch", "v7 pos", "v7 size", "v7 vfilt", "v7 amp", "v7 pitch"}
    for n = 1, S.constants.NUM_LFOS do
      for index, destination in ipairs(S.LFO_DESTINATIONS) do
        if destination.label == labels[n] then params:set(S.lib.lfos.param_id(n, "dest"), index) end
      end
      params:set(S.lib.lfos.param_id(n, "depth"), 100)
      if n > 1 then
        params:set(S.lib.lfos.param_id(n, "rate_mod"), n)
        params:set(S.lib.lfos.param_id(n, "depth_mod"), n)
      end
      params:set(S.lib.lfos.param_id(n), 1)
    end
  end

  local function state(name, id, setup)
    return {name = name, setup = function(context)
      if setup then setup(context) end
      if id then M.place(id) end
    end}
  end

  local function view_state(name, open, row, column, setup)
    return {name = name, setup = function(context)
      if setup then setup(context) end
      open()
      if column then
        S.mod_page.target_row, S.mod_page.target_column = row, column
      else
        S.mod_page.routing_row = row
      end
    end}
  end

  local layout_states = {
    state("bank row", "bank"),
    state("bank 4, M16 with eight widest targets", "source:macro16", function()
      widest_targets(); S.lib.macros.set_bank(4)
    end),
    state("morph A, a twelve-letter scene name", "morph_a", function()
      S.lib.scenes.set_name(16, "WWWWWWWWWWWW"); params:set("morph_a", 16); params:set("morph_b", 15)
    end),
    state("morph at 100%", "morph", function() params:set("morph", 1) end),
    state("scatter on", "scatter", function() params:set("scatter", 1) end),
    state("scatter amp, depth and rate at the top", "scatter_amp", function()
      params:set("scatter_depth", 100); params:set("scatter_rate", 1)
    end),
    state("G1, every recorder state", "source:gesture1", every_recorder_state),
    state("G4 recording", "source:gesture4", every_recorder_state),
    state("L1, six LFOs engine-run and modulated", "source:lfo1", engine_lfos),
    state("L6, six LFOs engine-run and modulated", "source:lfo6", engine_lfos),
    state("R1 empty, R2 off, R3 incomplete, R4 unknown", "routing:1", function()
      S.lib.matrix.set_routing(2, "lfo1", "v1_grain_size"); params:set(depth_id(2), 50); params:set(on_id(2), 0)
      S.lib.matrix.set_routing(3, "macro16", "")
      S.lib.matrix.set_routing(4, "a_later_source_key", "v7_a_later_destination")
    end),
    state("R1, all 16 routings at their widest", "routing:1", widest_routings),
    state("R16, all 16 routings at their widest", "routing:16", widest_routings),
    state("IN, the input level", "source:input"),
    state("a section registered by a test", "source:layout probe", function()
      S.register_mod_source({key = "layout probe", name = "WWWW", section = "a section of a later release",
        range = {-1, 1}, value = function() return 0 end, describe = function() return string.rep("W", 30) end})
    end),
    -- ALT's widest hints: K2:cancel E2:bank E3:fine, and a held K2 on a
    -- playing recorder (K2:clear K3:dub)
    {name = "ALT+K2 held past the hold time", setup = function(context)
      M.place("source:macro1")
      key(1, 1); key(2, 1)
      context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
    end},
    {name = "ALT+K2 held on a playing recorder", setup = function(context)
      every_recorder_state(context)
      M.place("source:gesture2")
      key(1, 1); key(2, 1)
      context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
    end},
  }
  for _, row in ipairs({1, MACRO_TARGETS}) do
    for column, name in ipairs(MOD_PAGE.columns) do
      table.insert(layout_states, view_state("M16 targets, row " .. row .. ", " .. name,
        function() open_targets(16) end, row, column, widest_targets))
    end
  end
  table.insert(layout_states, view_state("M1 targets, empty, learning row 2", function()
    open_targets(1); S.lib.macros.learn(1, 2)
  end, 2, 1))
  for row, name in ipairs(MOD_PAGE.routing_rows) do
    table.insert(layout_states, view_state("R16 routing, " .. name, function() open_routing(16) end, row, nil,
      widest_routings))
  end
  table.insert(layout_states, view_state("R4 routing, unknown parts", function()
    S.lib.matrix.set_routing(4, "a_later_source_key", "v7_a_later_destination"); open_routing(4)
  end, 2))

  -- The page's record, at MOD's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/mod.lua's
  S.registry.pages[UI_PAGES.index.MOD] = {name = "MOD", draw = redraw_mod, hints = mod_hints,
    enc = mod_enc, alt_enc = mod_alt_enc, key = mod_key, alt_key = mod_alt_key,
    alt_key_release = mod_alt_key_release, alt_hold = mod_alt_hold, alt_hold_hint = mod_alt_hold_hint,
    randomize_section = mod_randomize_section, animates = mod_animates, leave = mod_leave,
    arc_button = mod_arc_button, layout_states = layout_states}

  return M
end

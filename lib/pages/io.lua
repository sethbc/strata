-- lib/pages/io.lua
-- The IO page (3.6, design §11): a row page on S.lib.ui_field_list, in
-- sections each module registers with S.register_io_section (lib/state.lua).
-- The page owns no setting of its own: its rows edit params, the rig
-- settings (S.lib.io_rig, the only place they change), run actions or show
-- a status. E2 moves over the rows, E3 edits, K2 jumps to the next section,
-- K3 runs an action or opens a detail list (through S.lib.ui_modal), ALT+E2
-- selects the voice. Registers its S.registry.pages record. See
-- docs/notes/lua/pages/io.md.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local field_list = S.lib.ui_field_list

  local IO_PAGE = {
    visible = 6,          -- rows at y 18-53, 7 px apart, clear of the hint row (as SETUP)
    first_y = 18,
    spacing = 7,
    value_right = 124,    -- the scroll marker owns x 127
    -- the sections in the order they show; a registered name not listed
    -- here follows them, in registration order
    sections = {"voice", "midi", "crow", "ii", "wtape", "controllers", "remote", "osc", "tape"},
    row_indent = 4,       -- a section's rows start here, under its title at x 0
    value_gap = 4,        -- the least space between a label and its value (a longer value is cut)
    title_level = 10,     -- a title and its status
    note_level = 4,       -- a status row
    texts = {empty = "no sections", error = "error", not_saved = "setting not saved"},
    -- what each row kind needs: its fields and their types ("function" or
    -- "string"; "text" a string or a function)
    kinds = {
      param = {param_id = "string"},
      rig = {key = "string"},
      action = {run = "function", hint = "string"},
      status = {text = "text"},
      detail = {text = "function", fields = "table"},
    },
  }
  M.IO_PAGE = IO_PAGE

  S.io_cursor = 1         -- a row index into M.rows(), always a selectable row when there is one
  local view = {tail = 0}  -- rows the view is scrolled past the cursor's (field_list.move_scroll)
  local section_errors = {}  -- contained_call's last message per section part
  local detail = {rows = nil, cursor = 1, owner = nil}  -- the open detail list

  local function contained(part, label, fn, ...)
    return S.lib.ui_frame.contained_call(section_errors, part, label, fn, ...)
  end

  -- The registered sections in IO_PAGE.sections' order, the rest after
  -- them in registration order
  local function ordered_sections()
    local rank = {}
    for index, name in ipairs(IO_PAGE.sections) do rank[name] = index end
    local entries = {}
    for index, section in ipairs(S.registry.io_sections) do
      entries[#entries + 1] = {section = section, rank = rank[section.name] or (#IO_PAGE.sections + index)}
    end
    table.sort(entries, function(a, b) return a.rank < b.rank end)
    local sections = {}
    for index, entry in ipairs(entries) do sections[index] = entry.section end
    return sections
  end

  local function text_of(value)
    if type(value) == "function" then value = value() end
    return value ~= nil and tostring(value) or nil
  end

  -- What a param row shows: its format, its binary texts or the param's own string
  local function param_text(row)
    local value = params:get(row.param_id)
    if row.format then return string.format(row.format, value) end
    if row.binary then return row.binary[value] or tostring(value) end
    return params:string(row.param_id)
  end

  local function is_binary(row)
    return row.binary ~= nil or params:lookup_param(row.param_id).t == params.tBINARY
  end

  -- A row a section gave, checked and copied with what it shows (shown)
  -- and its section's name; it raises for a row the page cannot draw
  local function entry_for(row, section_name, allowed)
    if type(row) ~= "table" then error("a row is a table", 0) end
    local needs = IO_PAGE.kinds[row.kind]
    if not needs or (allowed and not allowed[row.kind]) then error("a row of kind " .. tostring(row.kind), 0) end
    if row.kind ~= "status" and type(row.label) ~= "string" then error("a " .. row.kind .. " row needs a label", 0) end
    for field, kind in pairs(needs) do
      local value = row[field]
      local ok = kind == "text" and (type(value) == "string" or type(value) == "function") or type(value) == kind
      if not ok then error("a " .. row.kind .. " row's " .. field .. " is a " .. kind, 0) end
    end
    if row.kind == "param" and not params.lookup[row.param_id] then error("no param " .. row.param_id, 0) end
    if row.kind == "rig" and not S.lib.io_rig.RIG.specs[row.key] then error("no rig setting " .. row.key, 0) end
    local entry = {}
    for field, value in pairs(row) do entry[field] = value end
    entry.section = section_name
    entry.selectable = row.kind ~= "status"
    if row.kind == "param" then entry.shown = param_text(row)
    elseif row.kind == "rig" then entry.shown = S.lib.io_rig.text(row.key)
    else entry.shown = text_of(row.text) end
    return entry
  end

  -- One section's rows: its title row (the title, its status at the
  -- right), then each of its rows. A title, rows or status that raises is
  -- contained (one console line per new message): the title row then says
  -- error and the section shows no rows
  local function add_section(rows, section)
    local name = section.name
    local title_row = {kind = "title", section = name, selectable = false, text = name}
    rows[#rows + 1] = title_row
    local failed = false
    if not contained(name .. " title", "io section " .. name .. " title", function()
      title_row.text = text_of(section.title) or name
    end) then failed = true end
    local entries = {}
    if not contained(name .. " rows", "io section " .. name .. " rows", function()
      local given = section.rows()
      if type(given) ~= "table" then error("rows() returns a list of rows", 0) end
      for index, row in ipairs(given) do entries[index] = entry_for(row, name) end
    end) then failed, entries = true, {} end
    if section.status and not contained(name .. " status", "io section " .. name .. " status", function()
      title_row.status = text_of(section.status())
    end) then failed = true end
    if failed then title_row.status = IO_PAGE.texts.error end
    for _, entry in ipairs(entries) do rows[#rows + 1] = entry end
  end

  -- The page's rows, rebuilt at each use: every registered section's title
  -- row and rows, in ordered_sections' order
  function M.rows()
    local rows = {}
    for _, section in ipairs(ordered_sections()) do add_section(rows, section) end
    return rows
  end

  -- The row under the cursor, or nil (no selectable row)
  local function cursor_row(rows)
    S.io_cursor = field_list.clamp(rows, S.io_cursor)
    local row = rows[S.io_cursor]
    if row and row.selectable then return row end
    return nil
  end

  local function flash_not_saved()
    S.lib.ui_flash.start("hints", IO_PAGE.texts.not_saved, nil, UI_PAGES.index.IO)
  end

  -- E3 on a param or rig row (fine: ALT+E3 on a rig row): a binary param
  -- is set to 1 or 0 (set_binary_param, which echoes it to a MIDI map);
  -- any other through enc_param_delta (ALT+E3 turns it finely there); a
  -- rig setting steps, and a write that fails flashes on the hint row
  local function edit(row, d, fine)
    if row.kind == "param" then
      if is_binary(row) then
        set_binary_param(row.param_id, d > 0 and 1 or 0)
      else
        enc_param_delta(3, row.param_id, d)
      end
    elseif row.kind == "rig" then
      if not S.lib.io_rig.step(row.key, d, fine) then flash_not_saved() end
    end
  end

  -- Draw one row at y: a title at x 0 with its status right-aligned; a
  -- status row's text; any other row's label at row_indent, its value
  -- right-aligned at value_right and cut to the room the label leaves
  local function draw_row(row, y, selected, value_right)
    local cut = S.lib.ui_text.fit_text
    if row.kind == "title" then
      screen.level(IO_PAGE.title_level)
      local status_width = 0
      if row.status then
        status_width = screen.text_extents(row.status) + IO_PAGE.value_gap
        screen.move(value_right, y)
        screen.text_right(row.status)
      end
      screen.move(0, y)
      screen.text(cut(row.text, value_right - status_width))
      return
    end
    local x = IO_PAGE.row_indent
    screen.move(x, y)
    if row.kind == "status" then
      screen.level(IO_PAGE.note_level)
      screen.text(cut(row.shown or "", value_right - x))
      return
    end
    screen.level(selected and 15 or 4)
    local label = cut(row.label, value_right - x)
    screen.text(label)
    if row.shown and row.shown ~= "" then
      local room = value_right - x - screen.text_extents(label) - IO_PAGE.value_gap
      screen.move(value_right, y)
      screen.text_right(cut(row.shown, room))
    end
  end

  local function draw_list(rows, cursor, tail)
    field_list.draw(rows, cursor, {visible = IO_PAGE.visible, first_y = IO_PAGE.first_y, spacing = IO_PAGE.spacing,
      value_right = IO_PAGE.value_right, tail = tail}, draw_row)
  end

  local function redraw_io()
    local rows = M.rows()
    if #rows == 0 then
      screen.level(IO_PAGE.note_level)
      screen.move(0, IO_PAGE.first_y)
      screen.text(IO_PAGE.texts.empty)
      return
    end
    cursor_row(rows)
    draw_list(rows, S.io_cursor, view.tail)
  end

  -- The detail list (a detail row's K3): its label as a title, then its
  -- fields (param and rig rows), as a modal owner: E2 moves, E3 edits the
  -- field under its cursor (ALT+E3 finely), K2 closes it
  local function detail_rows()
    local rows = {{kind = "title", selectable = false, text = detail.label}}
    local allowed = {param = true, rig = true}
    for _, field in ipairs(detail.fields) do rows[#rows + 1] = entry_for(field, detail.section, allowed) end
    return rows
  end

  local function close_detail()
    if detail.owner then S.lib.ui_modal.pop(detail.owner) end
    detail.owner = nil
  end

  local detail_owner = {
    draw = function()
      local rows = detail_rows()
      detail.cursor = field_list.clamp(rows, detail.cursor)
      draw_list(rows, detail.cursor, 0)
    end,
    hints = function(alt_held)
      return alt_held and "E2:field E3:fine" or "E2:field E3:value K2:close"
    end,
    enc = function(n, d)
      local rows = detail_rows()
      if n == 2 then
        detail.cursor = field_list.move(rows, detail.cursor, d)
      elseif n == 3 then
        local row = rows[field_list.clamp(rows, detail.cursor)]
        if row and row.selectable then edit(row, d, S.alt_held) end
      end
    end,
    key = function(n, z)
      if n == 2 and z == 1 then close_detail() end
    end,
  }

  local function open_detail(row)
    detail.label, detail.fields, detail.section, detail.cursor = row.label, row.fields, row.section, 1
    -- a detail whose fields cannot be drawn is contained like its section
    if not contained(row.section .. " detail", "io section " .. row.section .. " detail", detail_rows) then return end
    detail.owner = detail_owner
    S.lib.ui_modal.push(detail_owner)
  end

  -- The first selectable row of the section after the cursor's, wrapping
  -- to the list's first; nil with no selectable row
  local function next_section_row(rows, cursor)
    local current = rows[cursor] and rows[cursor].section
    for index = cursor + 1, #rows do
      if rows[index].selectable and rows[index].section ~= current then return index end
    end
    for index = 1, #rows do
      if rows[index].selectable then return index end
    end
    return nil
  end

  local function io_enc(n, d)
    local rows = M.rows()
    if n == 2 then
      S.io_cursor, view.tail = field_list.move_scroll(rows, S.io_cursor, view.tail, d, IO_PAGE.visible)
    elseif n == 3 and view.tail > 0 then
      view.tail = 0  -- E3 brings the cursor's row back before it edits (as SETUP)
    elseif n == 3 then
      local row = cursor_row(rows)
      if row then edit(row, d, false) end
    end
  end

  -- With ALT held: E2 selects the voice the voice section shows; E3 on a
  -- rig row steps it finely (osc_port by 1). Anything else goes on to
  -- io_enc (where enc_param_delta turns a param finely itself)
  local function io_alt_enc(n, d)
    if n == 2 then
      S.lib.ui_keys.select_voice_by(d)
      return true
    end
    if n == 3 and view.tail == 0 then
      local row = cursor_row(M.rows())
      if row and row.kind == "rig" then
        edit(row, d, true)
        return true
      end
    end
    return false
  end

  local function io_key(n)
    local rows = M.rows()
    local row = cursor_row(rows)
    if n == 2 then
      local index = next_section_row(rows, S.io_cursor)
      if index then S.io_cursor, view.tail = index, 0 end
    elseif n == 3 and row and row.kind == "action" then
      contained(row.section .. " action", "io section " .. row.section .. " action", row.run)
    elseif n == 3 and row and row.kind == "detail" then
      open_detail(row)
    end
  end

  -- The hint row follows the cursor row's kind; with ALT held, E2 selects
  -- the voice and E3 is offered only where it turns finely
  local function io_hints(alt_held)
    local rows = M.rows()
    local row = cursor_row(rows)
    if alt_held then
      local fine = row and view.tail == 0 and (row.kind == "rig"
        or (row.kind == "param" and params:lookup_param(row.param_id).t == params.tCONTROL))
      return fine and "E2:voice E3:fine" or "E2:voice"
    end
    if #rows == 0 then return "E1:page" end
    if view.tail > 0 then return "E2:row E3:back" end
    if not row then return "E2:row" end
    if row.kind == "action" then return "E2:row K2:section K3:" .. row.hint end
    if row.kind == "detail" then return "E2:row K2:section K3:open" end
    return "E2:row E3:value K2:section"
  end

  -- The cursor on section name's first selectable row, its title at the top
  -- of the list (or as near it as the list's end allows); false when no
  -- such section shows or it has no selectable row
  function M.show_section(name)
    local rows = M.rows()
    for index, row in ipairs(rows) do
      if row.kind == "title" and row.section == name then
        for field_index = index + 1, #rows do
          local field = rows[field_index]
          if field.section ~= name then break end
          if field.selectable then
            S.io_cursor, view.tail = field_index, 0
            return true
          end
        end
        return false
      end
    end
    return false
  end

  -- The page's record, at IO's place in UI_PAGES (the tenth: appended, so
  -- no other page's index moved). No arc fields yet (lib/arc/io.lua, the
  -- tape's rings, comes later); its layout states are its own (ALT's hint
  -- row), then the sections'
  local layout_states = {
    {name = "ALT held", setup = function() key(1, 1) end},
  }
  local own_layout_states = #layout_states
  S.registry.pages[UI_PAGES.index.IO] = {name = "IO", draw = redraw_io, hints = io_hints, enc = io_enc,
    alt_enc = io_alt_enc, key = io_key, leave = close_detail, layout_states = layout_states}

  -- init's start step: after the page's own, per registered section, in the page's order, a
  -- state with it at the top of the list, then each of its own states run
  -- after the same (S.registry.io_sections is read here, so a section
  -- registered by a module included after this one counts too)
  S.register_start(S.constants.START_ORDER.io_layout_states, function()
    for index = #layout_states, own_layout_states + 1, -1 do layout_states[index] = nil end
    for _, section in ipairs(ordered_sections()) do
      local name = section.name
      table.insert(layout_states, {name = name .. " at the top", setup = function() M.show_section(name) end})
      for _, state in ipairs(section.layout_states or {}) do
        table.insert(layout_states, {name = name .. ": " .. state.name, setup = function(context)
          M.show_section(name)
          state.setup(context)
        end})
      end
    end
  end)

  return M
end

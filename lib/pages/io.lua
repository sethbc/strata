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
    -- the draw that first shows the cursor on a row it fell to (its own
    -- row went: view.unseen) marks that row at x 0, before its label at
    -- row_indent (#902)
    unseen_mark = ">",
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
  -- tail: rows the view is scrolled past the cursor's (field_list.move_scroll);
  -- pinned: the section whose title show_section put at the top of the
  -- view, until E2 or K2 moves; anchor: which row the cursor is on (its
  -- section, label and their count so far, row_ids) and index the place it
  -- was put at, so the cursor follows its row when rows come or go above it
  -- unseen: the cursor fell to another row (its own went) that no draw has
  -- shown lit yet
  local view = {tail = 0, pinned = nil, anchor = nil, index = 1, unseen = false}
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
    if row.id ~= nil and type(row.id) ~= "string" and type(row.id) ~= "number" then
      error("an id is a string or a number", 0)
    end
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

  -- Each row's identity, so a row keeps it when others come or go around
  -- it: its section and its own name where it has one (a param row's
  -- param_id, a rig row's key, else an id the section gave it), else its
  -- label; then how many rows of that section and name came before it
  local function row_ids(rows)
    local seen, ids = {}, {}
    for index, row in ipairs(rows) do
      local own = row.kind == "title" and "title"
        or (row.kind == "param" and row.param_id and ("param " .. row.param_id))
        or (row.kind == "rig" and row.key and ("rig " .. row.key))
        or (row.id ~= nil and ("id " .. tostring(row.id)))
        or ("label " .. tostring(row.label))
      local base = tostring(row.section) .. "\n" .. own
      seen[base] = (seen[base] or 0) + 1
      ids[index] = base .. "\n" .. seen[base]
    end
    return ids
  end

  -- The cursor on rows[index] (the nearest selectable row at or before it),
  -- remembering which row that is
  local function place(rows, index)
    S.io_cursor = field_list.clamp(rows, index)
    view.index, view.anchor = S.io_cursor, row_ids(rows)[S.io_cursor]
  end

  -- After the rows are rebuilt (every use): the cursor back on the row it
  -- was on, wherever that row is now; when it is gone, the nearest
  -- selectable row at or before its old place, and true (lost: that row
  -- has never been shown under the cursor). A cursor set from outside
  -- (S.io_cursor not where place put it) is taken where it is
  local function follow(rows)
    if S.io_cursor ~= view.index or view.anchor == nil then
      place(rows, S.io_cursor)
      return false
    end
    for index, id in ipairs(row_ids(rows)) do
      if id == view.anchor and rows[index].selectable then
        place(rows, index)
        return false
      end
    end
    place(rows, view.index)
    return rows[S.io_cursor] ~= nil and rows[S.io_cursor].selectable == true
  end

  -- The row under the cursor once it has followed its row, or nil (no
  -- selectable row); and whether its own row had gone (follow)
  local function cursor_row(rows)
    if follow(rows) then view.unseen = true end
    local row = rows[S.io_cursor]
    if row and row.selectable then return row end
    return nil
  end

  -- E3 and K3 on a row the cursor fell to (its own row gone) that no draw
  -- has shown under the cursor yet: they only ask for that draw
  local function unseen()
    if not view.unseen then return false end
    request_redraw()
    return true
  end

  -- The pinned section's title row, or nil (none, or it no longer shows)
  local function pinned_title(rows)
    if not view.pinned then return nil end
    for index, row in ipairs(rows) do
      if row.kind == "title" and row.section == view.pinned then return index end
    end
    view.pinned = nil
    return nil
  end

  -- Whether the cursor's row is out of view: scrolled past it (tail), or a
  -- pinned section shown at the top without it. E3 and K3 then only bring
  -- it back, as SETUP's scrolled view does
  local function hidden(rows)
    if view.tail > 0 then return true end
    local title = pinned_title(rows)
    if not title then return false end
    local first = field_list.first_visible(rows, title + 1, IO_PAGE.visible, 0)
    return S.io_cursor < first or S.io_cursor >= first + IO_PAGE.visible
  end

  local function unhide()
    view.tail, view.pinned = 0, nil
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

  -- The unseen mark beside the row at y (the cursor's, in the draw that
  -- first shows it)
  local function draw_unseen_mark(y)
    screen.level(15)
    screen.move(0, y)
    screen.text(IO_PAGE.unseen_mark)
  end

  -- The list from cursor (scrolled tail rows past it), marked_row (or nil)
  -- with the unseen mark
  local function draw_list(rows, cursor, tail, marked_row)
    field_list.draw(rows, cursor, {visible = IO_PAGE.visible, first_y = IO_PAGE.first_y, spacing = IO_PAGE.spacing,
      value_right = IO_PAGE.value_right, tail = tail}, function(row, y, selected, value_right)
      draw_row(row, y, selected, value_right)
      if row == marked_row then draw_unseen_mark(y) end
    end)
  end

  local function redraw_io()
    local rows = M.rows()
    if #rows == 0 then
      screen.level(IO_PAGE.note_level)
      screen.move(0, IO_PAGE.first_y)
      screen.text(IO_PAGE.texts.empty)
      return
    end
    local cursor_entry = cursor_row(rows)
    -- this draw shows the cursor's row, marked when it was unseen
    local marked_row = view.unseen and cursor_entry or nil
    view.unseen = false
    local title = pinned_title(rows)
    if title then
      -- the view from the pinned title: field_list.draw shows the row after
      -- the title as if it held the cursor (so the title is the row above,
      -- at the top), and the real cursor's row is the one lit
      field_list.draw(rows, title + 1, {visible = IO_PAGE.visible, first_y = IO_PAGE.first_y,
        spacing = IO_PAGE.spacing, value_right = IO_PAGE.value_right, tail = 0}, function(row, y, _, value_right)
        draw_row(row, y, row == cursor_entry, value_right)
        if row == marked_row then draw_unseen_mark(y) end
      end)
      return
    end
    draw_list(rows, S.io_cursor, view.tail, marked_row)
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
    local row = cursor_row(rows)
    if n == 2 then
      view.pinned = nil
      local cursor
      cursor, view.tail = field_list.move_scroll(rows, S.io_cursor, view.tail, d, IO_PAGE.visible)
      place(rows, cursor)
      view.unseen = false
    elseif n == 3 and unseen() then
      return
    elseif n == 3 and hidden(rows) then
      unhide()  -- E3 brings the cursor's row back before it edits (as SETUP)
    elseif n == 3 and row then
      edit(row, d, false)
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
    if n == 3 then
      local rows = M.rows()
      local row = cursor_row(rows)
      if unseen() then return true end
      if row and row.kind == "rig" and not hidden(rows) then
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
      unhide()
      if index then place(rows, index) end
      view.unseen = false
    elseif n == 3 and unseen() then
      return
    elseif n == 3 and hidden(rows) then
      unhide()  -- K3 acts only on a row in view
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
      local fine = row and not hidden(rows) and (row.kind == "rig"
        or (row.kind == "param" and params:lookup_param(row.param_id).t == params.tCONTROL))
      return fine and "E2:voice E3:fine" or "E2:voice"
    end
    if #rows == 0 then return "E1:page" end
    if not row then return "E2:row" end
    if hidden(rows) then return "E2:row E3:back" end
    if row.kind == "action" then return "E2:row K2:section K3:" .. row.hint end
    if row.kind == "detail" then return "E2:row K2:section K3:open" end
    return "E2:row E3:value K2:section"
  end

  -- Section name's title at the top of the view (or as near it as the
  -- list's end allows), whether or not the section has a selectable row
  -- (one without its device may show only status rows): the cursor on its
  -- first selectable row; with none, on the nearest selectable row before
  -- it, else the first after it, else where it is. true when the section
  -- is registered (it then always shows its title row), false otherwise
  function M.show_section(name)
    local rows = M.rows()
    local title
    for index, row in ipairs(rows) do
      if row.kind == "title" and row.section == name then
        title = index
        break
      end
    end
    if not title then return false end
    follow(rows)
    local target
    for index = title + 1, #rows do
      if rows[index].section ~= name then break end
      if rows[index].selectable then
        target = index
        break
      end
    end
    for index = title - 1, 1, -1 do
      if target then break end
      if rows[index].selectable then target = index end
    end
    for index = title + 1, #rows do
      if target then break end
      if rows[index].selectable then target = index end
    end
    if target then place(rows, target) end
    view.tail, view.pinned, view.unseen = 0, name, false
    return true
  end

  -- The one way a layout state reaches a row, as a player does (#707):
  -- section shown, the first of its rows with match's identity (exactly
  -- one of param_id, key or id), E2 over the selectable rows between the
  -- cursor and it, the cursor checked to be on it. Returns the row; turns
  -- nothing and presses nothing (E3 or K3 on it is the caller's). Raises,
  -- naming who: no such section or row (the cursor where it was), or a
  -- cursor that did not land. Its preconditions, checked before it shows
  -- or turns anything (each a raise naming what is in the way): IO is the
  -- page shown (S.ui_page), no list is open over it (S.lib.ui_modal.top():
  -- E2 would go to the list; a caller that wants it closed closes it, this
  -- never does), ALT is not held (S.alt_held: E2 would select the voice)
  local REACH_FIELDS = {"param_id", "key", "id"}
  local function in_the_way()
    if S.ui_page ~= UI_PAGES.index.IO then return "the IO page is not shown" end
    local owner = S.lib.ui_modal.top()
    if owner == detail_owner then return "a detail list is open" end
    if owner then return "a list is open over the page" end
    if S.alt_held then return "ALT is held" end
    return nil
  end
  function M.go_to_row(who, section, match)
    local blocked = in_the_way()
    if blocked then error(tostring(who) .. " layout: " .. blocked, 0) end
    local field
    for _, name in ipairs(REACH_FIELDS) do
      if type(match) == "table" and match[name] ~= nil then
        if field then field = false break end
        field = name
      end
    end
    if not field then error(tostring(who) .. " layout: a match names one of param_id, key or id", 0) end
    local identity = field .. " " .. tostring(match[field])
    local function find(rows)
      for index, row in ipairs(rows) do
        if row.section == section and row.kind ~= "title" and row[field] == match[field] then return index end
      end
    end
    if not find(M.rows()) then error(tostring(who) .. " layout: no row " .. identity .. " in " .. tostring(section), 0) end
    M.show_section(section)
    local rows = M.rows()
    local target = find(rows)
    local from = S.io_cursor
    local moves = 0
    if target then
      for index = math.min(from, target), math.max(from, target) do
        if rows[index].selectable and index ~= from then moves = moves + 1 end
      end
      enc(2, target >= from and moves or -moves)
    end
    rows = M.rows()
    local row = rows[S.io_cursor]
    if not target or S.io_cursor ~= find(rows) then
      error(tostring(who) .. " layout: the cursor did not reach " .. identity, 0)
    end
    return row
  end

  -- The page's record, at IO's place in UI_PAGES (the tenth: appended, so
  -- no other page's index moved). Its arc fields are lib/arc/io.lua's (the
  -- tape's rings); its layout states are its own (ALT's hint row), then the
  -- sections'
  local layout_states = {
    {name = "ALT held", setup = function() key(1, 1) end},
  }
  local own_layout_states = #layout_states
  S.registry.pages[UI_PAGES.index.IO] = {name = "IO", draw = redraw_io, hints = io_hints, enc = io_enc,
    alt_enc = io_alt_enc, key = io_key, layout_states = layout_states,
    -- leaving ends a pinned view, so the next visit opens on the cursor's
    -- row. It closes no detail list: no page change happens under a modal
    -- owner (#899)
    leave = function()
      view.pinned = nil
    end}

  -- 3.9 (#902): the detail list is open (detail.owner set) exactly while
  -- its owner is the modal one, or beneath SEQ's step editor (the one owner
  -- a grid can push over it); closed, its owner is never the modal one
  S.register_invariant("io detail", function()
    local top = S.lib.ui_modal.top()
    if detail.owner == nil and top == detail_owner then return "the detail is closed but its owner is the modal one" end
    if detail.owner ~= nil and top ~= detail_owner
      and not (top == S.lib.pages_seq.step_editor_owner and S.lib.pages_seq.step_editor()) then
      return "the detail is open but the modal owner is " .. tostring(top) .. ", not its own"
    end
  end)

  -- init's start step: after the page's own, per registered section, in the page's order, a
  -- state with it at the top of the list, then each of its own states run
  -- after the same (S.registry.io_sections is read here, so a section
  -- registered by a module included after this one counts too)
  S.register_start(S.constants.START_ORDER.io_layout_states, function()
    for index = #layout_states, own_layout_states + 1, -1 do layout_states[index] = nil end
    -- two states of one name would write one render over the other: a
    -- repeat is refused, naming both owners
    local owners = {}
    local function add_states(name, states, owner)
      for _, state in ipairs(states or {}) do
        local full_name = name .. ": " .. state.name
        if owners[full_name] then
          error("io layout states: " .. owners[full_name] .. " and " .. owner .. " both have a state named \""
            .. full_name .. "\"", 0)
        end
        owners[full_name] = owner
        table.insert(layout_states, {name = full_name, setup = function(context)
          M.show_section(name)
          state.setup(context)
        end})
      end
    end
    -- the registered targets' states are the voice section's, after its own
    -- (or last, with no voice section)
    local function add_target_states()
      for _, target in ipairs(S.registry.note_targets) do add_states("voice", target.layout_states, "target " .. target.name) end
    end
    local voice_listed = false
    for _, section in ipairs(ordered_sections()) do
      local name = section.name
      table.insert(layout_states, {name = name .. " at the top", setup = function() M.show_section(name) end})
      add_states(name, section.layout_states, "section " .. name)
      if name == "voice" then add_target_states(); voice_listed = true end
    end
    if not voice_listed then add_target_states() end
  end)

  return M
end

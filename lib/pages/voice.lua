-- lib/pages/voice.lua
-- The VOICE page: every param of the selected voice, in the sections of
-- voice_page_rows (synth, grain, crossmod, mix, and the registered voice
-- params' rows and sections), through field_list. E2 moves the cursor
-- (S.cursors.voice), E3 edits its param (a binary row: on up, off down), K2/K3 jump to the
-- previous/next section, ALT+K2 resets the field to its default, ALT+K3
-- locks the voice; the arc button starts and stops it. Registers its
-- S.registry.pages record (every field but the arc fields, which are
-- lib/arc/voice.lua's). The cursor and its anchor are lib/ui/cursors.lua's;
-- sync_cursor and place_cursor (fields of S.lib.pages_voice) call it.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_VOICES = S.constants.NUM_VOICES
  local MAIN_PARAMS = S.constants.MAIN_PARAMS
  local field_list = S.lib.ui_field_list
  local fit_text = S.lib.ui_text.fit_text

  -- The page's positions: the selected voice (left) and the cursor's
  -- section with its position (right) on one line under the header, then
  -- the rows. Field labels sit 3 px in, after the ring group's 1 px marks
  -- at x 0; section labels start at x 0. Values end at value_right, clear
  -- of field_list's scroll marker at x 127.
  M.LAYOUT = {
    section_y = 16,
    first_y = 24,
    spacing = 7,
    visible = 5,         -- rows at y 24-52, clear of the hint row at y 62
    section_x = 0,
    field_x = 3,
    mark_x = 0,
    mark_height = 5,     -- a glyph's height: y - 4 .. y
    value_right = 124,
    value_gap = 4,       -- the least room between a label and its value
    line_gap = 6,        -- between the voice and the section on their line
  }
  local LAYOUT = M.LAYOUT

  -- The row's param key: its id without the "v<i>_" prefix
  local function param_key(row)
    return row and row.param_id and row.param_id:match("^v%d+_(.+)$")
  end

  -- The VOICE cursor's sync and deliberate placement are the cursor
  -- module's (S.lib.ui_cursors.sync("voice"), .place("voice", index)),
  -- which keeps its anchor; these are the page's names for them.
  -- sync_cursor() returns rows, cursor; every VOICE handler and the draw
  -- call it before reading the cursor
  function M.sync_cursor()
    return S.lib.ui_cursors.sync("voice")
  end

  function M.place_cursor(index)
    return S.lib.ui_cursors.place("voice", index)
  end

  -- The row index of param_id in the selected voice's current rows, or nil
  function M.row_of(param_id)
    for index, row in ipairs(voice_page_rows(S.selected_voice)) do
      if row.param_id == param_id then return index end
    end
  end

  -- The sections in rows, in order: {name, first = the first field's row index}
  local function sections_of(rows)
    local sections = {}
    for index, row in ipairs(rows) do
      if row.selectable == false then
        table.insert(sections, {name = row.section})
      elseif sections[#sections] and not sections[#sections].first then
        sections[#sections].first = index
      end
    end
    return sections
  end

  local function section_position(rows, cursor)
    local sections = sections_of(rows)
    for position, section in ipairs(sections) do
      if section.name == rows[cursor].section then return position, sections end
    end
    return 1, sections
  end

  -- A mod source's value: the voice's number and short name ("3 fold"), or "none"
  local function mod_source_text(value)
    if value < 1 or value > NUM_VOICES then return "none" end
    return value .. " " .. MAIN_PARAMS[S.voices[value].name].list_name
  end

  -- A row's value: the param's own string (its unit included), trailing
  -- spaces dropped; mod sources by voice name
  local function value_text(row)
    if param_key(row):match("^mod_source_%d+$") then
      return mod_source_text(params:get(row.param_id))
    end
    -- a binary param's own string is its number (norns' Binary:string)
    if row.kind == "binary" then return params:get(row.param_id) == 1 and "on" or "off" end
    return (params:string(row.param_id):gsub("%s+$", ""))
  end

  -- The rows the arc's rings edit (voice_page_group), marked while an arc
  -- is connected
  local function ring_rows(rows, cursor)
    local marked = {}
    if S.arc_connected then
      local _, row_indices = voice_page_group(rows, cursor)
      for _, index in ipairs(row_indices) do marked[rows[index]] = true end
    end
    return marked
  end

  -- The line under the header: "<n><+|-> <short name>[ [L]]" at the left,
  -- "<section> <k>/<n>" right-aligned
  local function draw_voice_line(rows, cursor)
    local position, sections = section_position(rows, cursor)
    local section_text = rows[cursor].section .. " " .. position .. "/" .. #sections
    screen.level(4)
    screen.move(LAYOUT.value_right, LAYOUT.section_y)
    screen.text_right(section_text)
    local voice = S.voices[S.selected_voice]
    local voice_text = S.selected_voice .. (voice.active and "+" or "-") .. " "
      .. MAIN_PARAMS[voice.name].list_name .. (S.frozen[S.selected_voice] and " [L]" or "")
    local room = LAYOUT.value_right - screen.text_extents(section_text) - LAYOUT.line_gap
    screen.level(10)
    screen.move(0, LAYOUT.section_y)
    screen.text(fit_text(voice_text, room))
  end

  local function draw_row(row, y, selected, marked)
    if row.selectable == false then
      screen.level(2)
      screen.move(LAYOUT.section_x, y)
      screen.text(row.label)
      return
    end
    if marked then
      screen.level(8)
      screen.rect(LAYOUT.mark_x, y - (LAYOUT.mark_height - 1), 1, LAYOUT.mark_height)
      screen.fill()
    end
    screen.level(selected and 15 or 4)
    screen.move(LAYOUT.field_x, y)
    screen.text(row.label)
    local room = LAYOUT.value_right - (LAYOUT.field_x + screen.text_extents(row.label)) - LAYOUT.value_gap
    screen.move(LAYOUT.value_right, y)
    screen.text_right(fit_text(value_text(row), room))
  end

  local function redraw_voice()
    local rows, cursor = M.sync_cursor()
    draw_voice_line(rows, cursor)
    local marked = ring_rows(rows, cursor)
    field_list.draw(rows, cursor, {visible = LAYOUT.visible, first_y = LAYOUT.first_y,
      spacing = LAYOUT.spacing, value_right = LAYOUT.value_right},
      function(row, y, selected) draw_row(row, y, selected, marked[row]) end)
  end

  -- The hint row (redraw() draws it after the page)
  local function voice_hints(alt_held)
    if alt_held then
      return "K2:reset K3:" .. (S.frozen[S.selected_voice] and "unlock" or "lock")
    end
    return "K2:prev K3:next"
  end

  local function voice_enc(n, d)
    local rows, cursor = M.sync_cursor()
    if n == 2 then
      S.lib.ui_cursors.move("voice", d)  -- anchors where it lands
    elseif n == 3 then
      local row = rows[cursor]
      if row.kind == "binary" then
        -- on with a turn up, off with a turn down (a toggle's delta would
        -- flip it either way)
        params:set(row.param_id, d > 0 and 1 or 0)
      else
        enc_param_delta(n, row.param_id, d)
      end
    end
  end

  -- K2: the first field of the section before the cursor's (in the first
  -- section, its own first field). K3: the next section's first field (in
  -- the last section, nothing)
  local function voice_key(n)
    local rows, cursor = M.sync_cursor()
    local position, sections = section_position(rows, cursor)
    local target
    if n == 2 then
      target = sections[math.max(position - 1, 1)]
    elseif n == 3 then
      target = sections[position + 1]
    end
    if target and target.first then
      M.place_cursor(target.first)
    end
  end

  -- ALT+K2: reset the field to its default; ALT+K3: lock or unlock the voice
  local function voice_alt_key(n)
    local rows, cursor = M.sync_cursor()
    if n == 2 then
      local param_id = rows[cursor].param_id
      params:set(param_id, param_default(param_id))
    elseif n == 3 then
      toggle_lock(S.selected_voice)
    end
  end

  -- The arc button on VOICE (design §7): start or stop the selected voice
  local function start_or_stop_selected_voice()
    toggle_voice(S.selected_voice)
  end

  -- The layout tests' and page renders' states: each voice with each
  -- source, the cursor on the first and the last field of every section
  local function source_option(name)
    for option, option_name in ipairs(S.constants.SOURCE_OPTIONS) do
      if option_name == name then return option end
    end
  end
  local LAYOUT_SOURCES = {
    {name = "synth", option = S.constants.SOURCE_SYNTH},
    {name = "buf 1", option = source_option("buf 1")},
    {name = "input", option = S.constants.SOURCE_INPUT},
  }
  local function layout_state(voice_idx, source, section, edge)
    return {
      name = string.format("v%d %s %s %s", voice_idx, source.name, section, edge),
      setup = function()
        S.selected_voice = voice_idx
        params:set("v" .. voice_idx .. "_source", source.option)
        local rows, target = voice_page_rows(voice_idx), nil
        for index, row in ipairs(rows) do
          if row.section == section and row.selectable ~= false and (edge == "last" or not target) then
            target = index
          end
        end
        M.place_cursor(target)
      end,
    }
  end
  local layout_states = {}
  for voice_idx = 1, NUM_VOICES do
    for _, source in ipairs(LAYOUT_SOURCES) do
      for _, section in ipairs({"synth", "grain", "crossmod", "mix"}) do
        if section ~= "synth" or source.option ~= S.constants.SOURCE_INPUT then
          for _, edge in ipairs({"first", "last"}) do
            table.insert(layout_states, layout_state(voice_idx, source, section, edge))
          end
        end
      end
    end
  end
  -- An arc marking the ring group, and a stopped, locked voice in triggered
  -- mode with a crossmod source by name
  table.insert(layout_states, {name = "arc ring group", setup = function(context)
    context.arc.plug(1)
    M.place_cursor(M.row_of("v1_grain_density"))  -- its ring group starts above the view
  end})
  table.insert(layout_states, {name = "locked voice", setup = function()
    S.selected_voice = 7
    toggle_lock(7)
    params:set("v7_grain_mode", 2)
    params:set("v7_mod_source_1", 5)
    M.place_cursor(M.row_of("v7_mod_source_1"))
  end})

  -- The page's record, at VOICE's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/voice.lua's
  S.registry.pages[UI_PAGES.index.VOICE] = {name = "VOICE", draw = redraw_voice, hints = voice_hints,
    enc = voice_enc, key = voice_key, alt_key = voice_alt_key, arc_button = start_or_stop_selected_voice,
    layout_states = layout_states}

  -- init's start step: every registered voice-param record's layout_states
  -- (S.registry.voice_params) after VOICE's own, so its rows are drawn by
  -- the layout tests and the page renders. Registries are read at init, so
  -- a record registered by a module included after this one counts too
  local own_layout_states = #layout_states
  S.register_start(S.constants.START_ORDER.voice_layout_states, function()
    for index = #layout_states, own_layout_states + 1, -1 do layout_states[index] = nil end
    for _, record in ipairs(S.registry.voice_params) do
      for _, state in ipairs(record.layout_states or {}) do table.insert(layout_states, state) end
    end
  end)

  return M
end

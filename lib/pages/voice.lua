-- lib/pages/voice.lua
-- The VOICE page: every param of the selected voice, in the sections of
-- voice_page_rows (synth, grain, crossmod, mix, and the registered voice
-- params' rows and sections), through field_list. E2 moves the cursor
-- (S.cursors.voice), E3 edits its param (a binary row: on up, off down), K2/K3 jump to the
-- previous/next section, ALT+K2 on release randomizes the cursor's section
-- or undoes it (S.lib.ui_alt's shared handler; held, it resets the field to
-- its default), ALT+K3 locks the voice; the arc button starts and stops it. Registers its
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
    -- the name is cut to leave room for the lock tag, never the tag (#421)
    local lock_tag = S.frozen[S.selected_voice] and " [L]" or ""
    local prefix = S.selected_voice .. (voice.active and "+" or "-") .. " "
    local room = LAYOUT.value_right - screen.text_extents(section_text) - LAYOUT.line_gap
    local name_room = room - screen.text_extents(prefix .. lock_tag)
    local voice_text = (prefix .. fit_text(MAIN_PARAMS[voice.name].list_name, name_room)):gsub("%s+$", "") .. lock_tag
    screen.level(10)
    screen.move(0, LAYOUT.section_y)
    screen.text(voice_text)
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

  -- ALT+K2's randomize (#557): the section under the cursor. A built-in
  -- row's draw is VOICE_DRAWS[key](param_id), a synthesis param's (the synth
  -- section of a synth voice) its whole controlspec, as MAIN's randomize; a
  -- registered row's its record's randomize[key](voice_idx). Any other row
  -- is kept: amp, the source, grain mode, the mod sources and the registered
  -- rows without a draw (freeze, the interval set, the filter's mix)
  local function uniform(low, high)
    return function() return low + math.random() * (high - low) end
  end
  local VOICE_DRAWS = {
    buf_pos = uniform(0, 1),                                    -- the buffer params: MAIN's ranges
    buf_rate = function() return 2 ^ (math.random() * 2 - 1) end,
    buf_scan = uniform(-0.5, 0.5),
    grain_size = uniform(0.05, 0.35),
    grain_density = uniform(2, 40),
    grain_pitch = uniform(0.5, 2.5),
    grain_spread = uniform(0, 0.6),
    grain_env = function(param_id) return math.random(params:lookup_param(param_id).count) end,
    mod_speed = function() return 0.2 * (10 / 0.2) ^ math.random() end,  -- 0.2-10 Hz, even in octaves
    pan = uniform(-0.8, 0.8),
  }
  for slot = 1, S.constants.NUM_MOD_SLOTS do
    VOICE_DRAWS["mod_amp_amt_" .. slot] = uniform(-0.5, 0.5)
    VOICE_DRAWS["mod_freq_amt_" .. slot] = uniform(-0.5, 0.5)
  end
  local function synth_param_draw(param_id) return params:lookup_param(param_id).controlspec:map(math.random()) end

  -- The draw of the selected voice's row (fn() -> value), or nil for a row
  -- the randomize keeps
  local function row_draw(voice_idx, row)
    local key = param_key(row)
    for _, record in ipairs(S.registry.voice_params) do
      local draw = record.randomize and record.randomize[key]
      if draw then return function() return draw(voice_idx) end end
    end
    local draw = VOICE_DRAWS[key]
    if not draw and row.section == "synth" and S.voices[voice_idx].params[key] ~= nil then draw = synth_param_draw end
    if draw then return function() return draw(row.param_id) end end
  end

  -- The record's randomize_section (S.lib.ui_alt's shared ALT+K2): the
  -- spec of the cursor's section, its rows' draws in row order (a buffer
  -- voice's loop start before its length; a Sub voice's mix has none, so
  -- its press does nothing), with "locked" for a locked voice. The spec's
  -- section is the rows' section, except a buffer voice's synth section
  -- (its buffer params and loop), which is "synth (buffer)": its undo is
  -- its own, so after a switch between synth and buffer a quick press
  -- never undoes rows the section no longer shows. The hint calls it on
  -- every draw while ALT is held: it builds the rows once
  local function voice_randomize_section()
    local rows, cursor = M.sync_cursor()
    local voice_idx = S.selected_voice
    local section = rows[cursor].section
    local draws = {}
    for _, row in ipairs(rows) do
      if row.section == section and row.selectable ~= false then
        local draw = row_draw(voice_idx, row)
        if draw then draws[#draws + 1] = {id = row.param_id, draw = draw} end
      end
    end
    local undo_section = section
    if section == "synth" and voice_uses_buffer(voice_idx) then undo_section = "synth (buffer)" end
    return {page = UI_PAGES.index.VOICE, section = undo_section, voice = voice_idx, draws = draws},
      S.frozen[voice_idx] and "locked" or nil
  end

  -- The hint row (redraw() draws it after the page): with ALT, ALT+K2's
  -- (the shared handler's: rand, undo or locked; reset once held past the
  -- hold time) and ALT+K3's (lock)
  local function voice_hints(alt_held)
    if alt_held then
      return S.lib.ui_alt.k2_hint(S.registry.pages[UI_PAGES.index.VOICE]) .. " K3:"
        .. (S.frozen[S.selected_voice] and "unlock" or "lock")
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
        set_binary_param(row.param_id, d > 0 and 1 or 0)
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

  -- ALT+K2 acts on release (voice_alt_key_release): the press only notes
  -- its time. ALT+K3: lock or unlock the voice, at the press
  local function voice_alt_key(n)
    if n == 2 then
      S.lib.ui_alt.k2_down()
    elseif n == 3 then
      toggle_lock(S.selected_voice)
    end
  end

  -- ALT+K2 released: a quick press randomizes the cursor's section or
  -- undoes its randomize (voice_randomize_section); one held past the hold
  -- time resets the row (voice_reset_row)
  local function voice_alt_key_release(n)
    if n == 2 then S.lib.ui_alt.k2_up(S.registry.pages[UI_PAGES.index.VOICE]) end
  end

  -- ALT+K2 held, the record's alt_hold: reset the field under the cursor to
  -- its default (a locked voice's too: a locked voice can still be edited)
  local function voice_reset_row()
    local rows, cursor = M.sync_cursor()
    local param_id = rows[cursor].param_id
    if rows[cursor].kind == "binary" then
      set_binary_param(param_id, param_default(param_id))  -- echoes to a MIDI map (#519)
    else
      params:set(param_id, param_default(param_id))
    end
  end

  -- The frame clock redraws VOICE while ALT+K2 is down, so its hint turns
  -- to K2:reset at the hold time
  local function voice_animates()
    return S.lib.ui_alt.k2_held()
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
  local function option_index(options, name)
    for option, option_name in ipairs(options) do
      if option_name == name then return option end
    end
  end
  table.insert(layout_states, {name = "locked voice", setup = function()
    local last = NUM_VOICES
    S.selected_voice = last
    toggle_lock(last)
    params:set("v" .. last .. "_grain_mode", option_index(S.constants.GRAIN_MODE_OPTIONS, "triggered"))
    params:set("v" .. last .. "_mod_source_1", math.max(last - 2, 1))  -- another voice, by name
    M.place_cursor(M.row_of("v" .. last .. "_mod_source_1"))
  end})
  -- a locked voice with the longest section label (#421): the lock tag must
  -- survive the cut of the voice text
  table.insert(layout_states, {name = "locked voice, filter & sends", setup = function()
    S.selected_voice = 1
    toggle_lock(1)
    M.place_cursor(M.row_of("v1_filter_mix"))
  end})
  -- ALT's hint row: the widest, K2:locked K3:unlock, and ALT+K2 held past
  -- the hold time (K2:reset)
  table.insert(layout_states, {name = "ALT held, voice locked", setup = function()
    toggle_lock(S.selected_voice)
    key(1, 1)
  end})
  table.insert(layout_states, {name = "ALT+K2 held past the hold time", setup = function(context)
    key(1, 1); key(2, 1)
    context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  end})

  -- The page's record, at VOICE's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/voice.lua's
  S.registry.pages[UI_PAGES.index.VOICE] = {name = "VOICE", draw = redraw_voice, hints = voice_hints,
    enc = voice_enc, key = voice_key, alt_key = voice_alt_key, alt_key_release = voice_alt_key_release,
    randomize_section = voice_randomize_section, alt_hold = voice_reset_row, animates = voice_animates,
    arc_button = start_or_stop_selected_voice, layout_states = layout_states}

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

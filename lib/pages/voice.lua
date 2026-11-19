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
    speed_format = "%.2fx",  -- buf_scan's value: a speed (3.7)
    pending_level = 4,       -- the type row's pending choice (3.8)
    no_preset = "--",        -- the preset row with nothing loaded (3.8)
    -- a row whose param is not used now (interval prob while the
    -- arpeggiator is on, #845): selected, and not
    unused_levels = {selected = 10, other = 2},
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

  -- The sections in rows, in order: {name, first = the first field's row
  -- index}. A section starts at a label row, or at a first row with none
  -- above it (3.8: the type row's section, "voice")
  local function sections_of(rows)
    local sections = {}
    for index, row in ipairs(rows) do
      if row.selectable == false then
        table.insert(sections, {name = row.section})
      elseif index == 1 then
        table.insert(sections, {name = row.section, first = index})
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
    return value .. " " .. S.lib.types.of(value).list_name
  end

  -- A row's value: the param's own string (its unit included), trailing
  -- spaces dropped; mod sources by voice name; a buffer voice's scan as a
  -- speed (3.7: "1.00x", 1 the audio's own rate)
  local function value_text(row)
    if row.kind == S.lib.ui_voice_rows.PRESET_KIND then
      -- the preset last loaded into the voice (3.8), as norns' font draws it
      local name = S.lib.voice_presets.loaded_name(S.selected_voice)
      return name and S.lib.ui_text.printable(name) or LAYOUT.no_preset
    end
    local key = param_key(row)
    if row.kind == S.lib.ui_voice_rows.TYPE_KIND then
      -- the pending choice's name while the row turns (3.8), else the type's
      local voice_idx = tonumber(row.param_id:match("^v(%d+)_"))
      local pending = S.lib.types.pending(voice_idx)
      if pending then return S.lib.types.list()[pending].name end
      return S.lib.types.of(voice_idx).name
    end
    if key:match("^mod_source_%d+$") then
      return mod_source_text(params:get(row.param_id))
    end
    if key == "buf_scan" then return string.format(LAYOUT.speed_format, params:get(row.param_id)) end
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
    local lock_tag = S.locked[S.selected_voice] and " [L]" or ""
    local prefix = S.selected_voice .. (voice.active and "+" or "-") .. " "
    local room = LAYOUT.value_right - screen.text_extents(section_text) - LAYOUT.line_gap
    local name_room = room - screen.text_extents(prefix .. lock_tag)
    local voice_text = (prefix .. fit_text(S.lib.types.of(S.selected_voice).list_name, name_room)):gsub("%s+$", "") .. lock_tag
    screen.level(10)
    screen.move(0, LAYOUT.section_y)
    screen.text(voice_text)
  end

  -- Whether the row's param is not used now: interval prob while the
  -- voice's arpeggiator is on (every grain takes the list's next step, #845)
  local function row_unused(row)
    return param_key(row) == "interval_prob" and S.lib.arp.on(S.selected_voice)
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
    if row_unused(row) then
      screen.level(selected and LAYOUT.unused_levels.selected or LAYOUT.unused_levels.other)
    else
      screen.level(selected and 15 or 4)
    end
    screen.move(LAYOUT.field_x, y)
    screen.text(row.label)
    local room = LAYOUT.value_right - (LAYOUT.field_x + screen.text_extents(row.label)) - LAYOUT.value_gap
    -- a pending type choice (3.8) is drawn dim until it applies
    if row.kind == S.lib.ui_voice_rows.TYPE_KIND and S.lib.types.pending(S.selected_voice) then
      screen.level(LAYOUT.pending_level)
    end
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
    if row.kind == S.lib.ui_voice_rows.PRESET_KIND then return nil end  -- no param (3.8)
    local key = param_key(row)
    for _, record in ipairs(S.registry.voice_params) do
      local draw = record.randomize and record.randomize[key]
      if draw then return function() return draw(voice_idx) end end
    end
    local draw = VOICE_DRAWS[key]
    if not draw and row.section == "synth" and S.lib.voices.is_synth_key(voice_idx, key) then draw = synth_param_draw end
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
      S.locked[voice_idx] and "locked" or nil
  end

  -- The hint row (redraw() draws it after the page): with ALT, ALT+K2's
  -- (the shared handler's: rand, undo or locked, none where a quick press
  -- draws nothing, #823; reset, or cancel on the preset row, once held past
  -- the hold time) and ALT+K3's (lock). K1 let go while ALT+K2 is down:
  -- K2's hint alone, since its release still acts
  local function voice_hints(alt_held)
    local record = S.registry.pages[UI_PAGES.index.VOICE]
    local k2 = S.lib.ui_alt.k2_hint(record)
    if alt_held then
      local k3 = "K3:" .. (S.locked[S.selected_voice] and "unlock" or "lock")
      return k2 and k2 .. " " .. k3 or k3
    end
    if S.lib.ui_alt.k2_held() then return k2 or "" end
    local rows, cursor = M.sync_cursor()
    if rows[cursor].kind == S.lib.ui_voice_rows.PRESET_KIND then return "K2:prev K3:pick" end
    return "K2:prev K3:next"
  end

  local function voice_enc(n, d)
    local rows, cursor = M.sync_cursor()
    if n == 2 then
      S.lib.ui_cursors.move("voice", d)  -- anchors where it lands
    elseif n == 3 then
      local row = rows[cursor]
      if row.kind == S.lib.ui_voice_rows.PRESET_KIND then
        return  -- the preset row (3.8): E3 does nothing; K3 opens the picker
      elseif row.kind == S.lib.ui_voice_rows.TYPE_KIND then
        -- the type row (3.8): a pending choice, applied once E3 rests
        S.lib.types.turn(S.selected_voice, d > 0 and 1 or -1)
      elseif row.kind == "binary" then
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
  -- the last section, nothing); on the preset row (3.8), the voice picker
  local function voice_key(n)
    local rows, cursor = M.sync_cursor()
    if n == 3 and rows[cursor].kind == S.lib.ui_voice_rows.PRESET_KIND then
      S.lib.ui_voice_picker.open(S.selected_voice)
      return
    end
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
    if rows[cursor].kind == S.lib.ui_voice_rows.PRESET_KIND then
      return  -- no param to reset (3.8)
    elseif rows[cursor].kind == S.lib.ui_voice_rows.TYPE_KIND then
      -- the voice's own type, at once (a pending choice canceled)
      S.lib.types.set(S.selected_voice, S.lib.types.default_key(S.selected_voice))
    elseif rows[cursor].kind == "binary" then
      set_binary_param(param_id, param_default(param_id))  -- echoes to a MIDI map (#519)
    else
      params:set(param_id, param_default(param_id))
    end
  end

  -- What ALT+K2 held does (the record's alt_hold_hint): reset, or cancel
  -- on the preset row, which voice_reset_row leaves alone (#823)
  local function voice_alt_hold_hint()
    local rows, cursor = M.sync_cursor()
    return rows[cursor].kind == S.lib.ui_voice_rows.PRESET_KIND and "cancel" or "reset"
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
    -- 3.8: a voice source (voice 7's ring: the longest option name)
    {name = "voice 7", option = source_option("voice " .. NUM_VOICES)},
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
      for _, section in ipairs({S.lib.ui_voice_rows.VOICE_SECTION, "synth", "grain", "crossmod", "mix"}) do
        -- (an input or voice-source voice has no synth section)
        if section ~= "synth" or source.option < S.constants.SOURCE_INPUT then
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
  -- interval prob dimmed (#845): the arpeggiator on, the cursor on the row
  table.insert(layout_states, {name = "interval prob, the arpeggiator on", setup = function()
    S.selected_voice = 1
    params:set("v1_arp", S.lib.arp.ARP.mode_index.up)
    M.place_cursor(M.row_of("v1_interval_prob"))
  end})
  -- ALT's hint row: the widest, K2:locked K3:unlock (on a row that draws),
  -- and ALT+K2 held past the hold time (K2:reset); on the type row, no
  -- quick K2 (K3:lock), and on the preset row the hold's K2:cancel (#823)
  table.insert(layout_states, {name = "ALT held, voice locked", setup = function()
    M.place_cursor(M.row_of("v" .. S.selected_voice .. "_freq"))
    toggle_lock(S.selected_voice)
    key(1, 1)
  end})
  table.insert(layout_states, {name = "ALT+K2 held past the hold time", setup = function(context)
    key(1, 1); key(2, 1)
    context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  end})
  table.insert(layout_states, {name = "ALT held on the type row", setup = function()
    M.place_cursor(1)
    key(1, 1)
  end})
  table.insert(layout_states, {name = "ALT+K2 held on the preset row past the hold time", setup = function(context)
    M.place_cursor(2)
    key(1, 1); key(2, 1)
    context.clock.run_for(S.constants.ALT_HOLD_SECONDS)
  end})

  -- 3.8 (package 3b): the preset row with a twelve-character name, and the
  -- voice picker (S.lib.ui_voice_picker) on a voice row, on slot 1 with a
  -- twelve-character name and the widest type, on slot 64 empty, with ALT
  -- held, with ALT+K2 past the hold time, a refused load's flash (K3 on an
  -- empty slot) and a load's (K3 on slot 1, its twelve-character name).
  -- Each reads the types and the library at its setup
  local function preset_name() return string.rep("W", S.constants.SCENE_NAME_MAX) end
  local function widest_type()
    local widest, width = nil, -1
    for _, record in ipairs(S.lib.types.list()) do
      local extent = screen.text_extents(record.list_name)
      if extent > width then widest, width = record, extent end
    end
    return widest
  end
  local function filled_slot_one()
    params:set("v2_type", widest_type().index)
    S.lib.voice_presets.save(2, 1, preset_name())
  end
  -- The picker open on voice 1, E2 turned row_moves rows from its first
  local function open_picker(row_moves, prepare)
    S.selected_voice = 1
    if prepare then prepare() end
    S.lib.ui_voice_picker.open(1)
    enc(2, row_moves)
  end
  local function slot_count() return S.lib.voice_presets.VOICE_PRESETS.slots end
  table.insert(layout_states, {name = "preset row, a twelve-character name", setup = function()
    S.selected_voice = 1
    S.lib.voice_presets.save(2, 1, preset_name())
    S.lib.voice_presets.load(1, 1)
    for index, row in ipairs(voice_page_rows(1)) do
      if row.kind == S.lib.ui_voice_rows.PRESET_KIND then M.place_cursor(index) end
    end
  end})
  table.insert(layout_states, {name = "voice picker, a voice row", setup = function() open_picker(0) end})
  table.insert(layout_states, {name = "voice picker, slot 1 named, the widest type", setup = function()
    open_picker(NUM_VOICES - 1, filled_slot_one)
  end})
  table.insert(layout_states, {name = "voice picker, slot 64 empty", setup = function()
    open_picker(NUM_VOICES - 1 + slot_count())
  end})
  table.insert(layout_states, {name = "voice picker, ALT held", setup = function()
    open_picker(NUM_VOICES - 1, filled_slot_one)
    key(1, 1)
  end})
  table.insert(layout_states, {name = "voice picker, ALT+K2 past the hold time", setup = function(context)
    open_picker(NUM_VOICES - 1, filled_slot_one)
    key(1, 1); key(2, 1)
    context.clock.run_for(S.lib.ui_voice_picker.VOICE_PICKER.hold_seconds)
  end})
  table.insert(layout_states, {name = "voice picker, a refused load's flash", setup = function()
    open_picker(NUM_VOICES)
    key(3, 1); key(3, 0)
  end})
  table.insert(layout_states, {name = "voice picker, a load's flash", setup = function()
    open_picker(NUM_VOICES - 1, filled_slot_one)
    key(3, 1); key(3, 0)
  end})

  -- The page's record, at VOICE's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/voice.lua's
  S.registry.pages[UI_PAGES.index.VOICE] = {name = "VOICE", draw = redraw_voice, hints = voice_hints,
    enc = voice_enc, key = voice_key, alt_key = voice_alt_key, alt_key_release = voice_alt_key_release,
    randomize_section = voice_randomize_section, alt_hold = voice_reset_row,
    alt_hold_hint = voice_alt_hold_hint, animates = voice_animates,
    arc_button = start_or_stop_selected_voice, layout_states = layout_states}

  -- 3.8: the type row holding a pending choice, drawn dim, toward the
  -- type at index (each type's name, the longest among them)
  local function type_pending_state(index)
    return {name = "type row pending " .. index, setup = function()
      S.selected_voice = 1
      M.place_cursor(1)
      local current = S.lib.types.of(1).index
      if index ~= current then S.lib.types.turn(1, index - current) end
    end}
  end

  -- init's start step: a pending type row toward each voice type (the
  -- types are read at init, never at include time), then every registered
  -- voice-param record's layout_states (S.registry.voice_params) after
  -- VOICE's own, so its rows are drawn by the layout tests and the page
  -- renders. Registries are read at init, so a record registered by a
  -- module included after this one counts too
  local own_layout_states = #layout_states
  S.register_start(S.constants.START_ORDER.voice_layout_states, function()
    for index = #layout_states, own_layout_states + 1, -1 do layout_states[index] = nil end
    for index = 1, #S.lib.types.list() do table.insert(layout_states, type_pending_state(index)) end
    for _, record in ipairs(S.registry.voice_params) do
      for _, state in ipairs(record.layout_states or {}) do table.insert(layout_states, state) end
    end
  end)

  return M
end

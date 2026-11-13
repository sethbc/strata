-- lib/pages/seq.lua
-- The SEQ page: all seven patterns, the transport and the tempo, in two
-- views. The pattern view: one row per voice (its number, sixteen cells at
-- the steps' levels, the steps past the voice's length as dots, a mark on
-- a gated voice, + or - for running), each row's playing column its own
-- voice's sounding step, a step cursor on the selected voice's row. E2
-- moves the step, E3 sets its level, K2 plays/stops, K3 turns the step on
-- or off; ALT+E2 moves to another voice's row (the selected voice
-- follows), ALT+E3 the tempo, ALT+K2 randomizes (on release, again within
-- 5 s to undo: the shared handler, S.lib.ui_alt; held 0.5 s, it opens the
-- edit view) and ALT+K3 clears the voice's pattern. The edit view (design
-- 8.6): the selected voice's step at S.cursors.seq_step as a field list of
-- the sections voice, step <n> and chain; E2 the row, E3 the value, ALT+E2
-- the step, ALT+E3 fine (the rotation on euclid); K2 back, K3 the step
-- on/off (clears on the clear row); ALT+K2 randomizes, held it resets the
-- row; ALT+K3 clears. The step editor (design 8.7): the same edit view for
-- any voice and step, pushed as a modal owner (S.lib.ui_modal) by the
-- grids over any page (open_step_editor, close_step_editor). The header
-- shows the tempo (header_status). Pattern edits write S.patterns within
-- bounds or go through the sequencer (lib/sequencer.lua: toggle, clear,
-- randomize, euclid, set_step_attr), and call grid_redraw(). Registers its
-- S.registry.pages record (every field but the arc fields, which are
-- lib/arc/seq.lua's, as are the step editor's rings). See
-- docs/notes/lua/pages/seq.md.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL
  local NUM_BOOKMARKS = S.constants.NUM_BOOKMARKS
  local ALT_HOLD_SECONDS = S.constants.ALT_HOLD_SECONDS
  local FINE_DIVISOR = S.constants.FINE_DIVISOR
  local field_list = S.lib.ui_field_list
  local fit_text = S.lib.ui_text.fit_text

  -- The pattern view (design §5): rows 6 px apart from y 13, each the
  -- voice's number at x 0 (baseline text_offset below the row's top), 16
  -- cells of 4x4 px, 6 px apart from x 10, and + or - right-aligned at 127.
  -- An empty step is an outline at empty_level, so a level-1 step never
  -- reads as empty. The playing column draws outlines at
  -- playing_outline_level and cells playing_boost brighter. The cursor is a
  -- 6x6 outline at 15. A step past the voice's length is a 1x1 dot at
  -- dot_level, dot_offset into its cell; a gated voice's row shows
  -- gate_mark right-aligned at gate_right (3.4)
  local SEQ_PAGE = {rows_y = 13, row_spacing = 6, label_x = 0, text_offset = 5, cells_x = 10,
    cell_spacing = 6, cell_size = 4, state_right = 127, empty_level = 1, playing_outline_level = 4,
    playing_boost = 4, cursor_level = 15, label_level = 4, selected_label_level = 15,
    dot_offset = 1, dot_level = 1, gate_mark = "G", gate_right = 121}

  -- The edit view (design 8.6): "v<voice> step <n>" at 0,line_y and a strip
  -- of the voice's steps (cells strip_cell px, strip_spacing apart from
  -- strip_x, their tops at strip_y; the step's outlined), then the rows as
  -- VOICE's (visible rows spacing apart from first_y, section labels at x
  -- 0, fields at field_x, values right-aligned at value_right). A view
  -- opens on its first_key row (the step editor on editor_first_key)
  local SEQ_EDIT = {line_y = 16, line_level = 10, strip_x = 60, strip_y = 13, strip_spacing = 4, strip_cell = 3,
    first_y = 24, spacing = 7, visible = 5, section_x = 0, field_x = 3, value_right = 124, value_gap = 4,
    section_level = 2, field_level = 4, selected_level = 15, first_key = "length", editor_first_key = "level"}

  -- The edit view's rows, in order (design 8.6, 8.12, 8.13): a section
  -- label, or a field with the row key its cursor remembers and what it
  -- edits: a voice param (voice_param, the id after "v<i>_"), a global
  -- param (param_id; binary for the chain's on/off), a step attribute
  -- (attr: the key of S.lib.sequencer.step_attr) or the step's level;
  -- format: how a param's value reads. bookmark shows only while the
  -- voice has a set bookmark (S.lib.bookmarks.is_set)
  local EDIT_ROWS = {
    {section = "voice"},
    {row = "length", label = "length", voice_param = "seq_length", format = "%d"},
    {row = "division", label = "division", voice_param = "seq_division"},
    {row = "swing", label = "swing", voice_param = "seq_swing", format = "%d%%"},
    {row = "gate", label = "gate", voice_param = "seq_gate"},
    {row = "gate_length", label = "gate len", voice_param = "seq_gate_length", format = "%.2f st"},
    {row = "gate_release", label = "gate rel", voice_param = "seq_gate_release", format = "%.2f s"},
    {row = "euclid", label = "euclid"},
    {row = "clear", label = "clear"},
    {section = "step"},
    {row = "level", label = "level", attr = "level"},
    {row = "prob", label = "prob", attr = "prob"},
    {row = "ratchet", label = "ratchet", attr = "ratchet"},
    {row = "step_gate", label = "gate", attr = "gate"},
    {row = "note", label = "note", attr = "notes", chord = true},
    {row = "pos", label = "pos", attr = "pos"},
    {row = "pitch", label = "pitch", attr = "pitch"},
    {row = "size", label = "size", attr = "size"},
    {row = "bookmark", label = "bookmark", attr = "bookmark"},
    {section = "chain"},
    {row = "chain", label = "chain", param_id = "seq_chain", binary = true},
    {row = "chain_from", label = "from", param_id = "seq_chain_from", format = "%d"},
    {row = "chain_scenes", label = "scenes", param_id = "seq_chain_scenes", format = "%d"},
    {row = "chain_bars", label = "bars", param_id = "seq_chain_bars", format = "%d"},
    {row = "quantize", label = "quantize", param_id = "quantize_actions"},
  }

  -- How a step attribute reads (pitch a ratio, as MAIN's pitch), and the
  -- param a step's gate moves on (the voice's gate length's range). The
  -- step locks' params are the sequencer's (SEQ.lock_params: lock_param_name)
  local ATTR_FORMATS = {pos = "%.2f", pitch = "%.2fx", size = "%.2f s", gate = "%.2f st"}
  local STEP_GATE_PARAM = "seq_gate_length"

  -- The chord's rows (design 9.4): note k of a step's list has row key
  -- "note" (the first) or "note<k>" and label "note" or "note <k>"; the add
  -- row follows them while the step has 1 to SEQ.max_step_notes - 1 notes.
  -- edit_rows expands EDIT_ROWS' "note" entry into them
  local NOTE_ADD_SPEC = {row = "note_add", label = "add note", attr = "notes", add = true}
  local note_specs = {}

  local function note_spec(index)
    local spec = note_specs[index]
    if spec == nil then
      spec = {row = index == 1 and "note" or ("note" .. index), label = index == 1 and "note" or ("note " .. index),
        attr = "notes", index = index}
      note_specs[index] = spec
    end
    return spec
  end

  -- The step under the cursor, on the selected voice's row
  local function cursor_step()
    return util.clamp(S.cursors.seq_step, 1, PATTERN_LENGTH)
  end

  local function valid_place(voice_idx, step)
    return type(voice_idx) == "number" and voice_idx % 1 == 0 and voice_idx >= 1 and voice_idx <= NUM_VOICES
      and type(step) == "number" and step % 1 == 0 and step >= 1 and step <= PATTERN_LENGTH
  end

  local function voice_param_id(voice_idx, name) return "v" .. voice_idx .. "_" .. name end

  local function voice_length(voice_idx) return params:get(voice_param_id(voice_idx, "seq_length")) end

  local function gated(voice_idx)
    return params:get(voice_param_id(voice_idx, "seq_gate")) == S.lib.sequencer.SEQ.gate_on
  end

  -- A pattern edit: the grid shows the patterns, so it follows at once. (The
  -- screen needs nothing here: enc and key in strata.lua request its redraw
  -- after every handler)
  local function pattern_changed()
    grid_redraw()
  end

  -- A cell size px square at x, y: filled at its level when set, an outline
  -- when empty; the playing column brighter
  local function draw_cell(x, y, level, playing, size)
    if level > 0 then
      screen.level(playing and math.min(MAX_STEP_LEVEL, level + SEQ_PAGE.playing_boost) or level)
      screen.rect(x, y, size, size)
      screen.fill()
    else
      screen.level(playing and SEQ_PAGE.playing_outline_level or SEQ_PAGE.empty_level)
      screen.rect(x, y, size, size)
      screen.stroke()
    end
  end

  -- A step past the voice's length: a 1x1 dot in its cell
  local function draw_dot(x, y)
    screen.level(SEQ_PAGE.dot_level)
    screen.rect(x + SEQ_PAGE.dot_offset, y + SEQ_PAGE.dot_offset, 1, 1)
    screen.fill()
  end

  local function redraw_pattern_view()
    for voice_idx = 1, NUM_VOICES do
      local y = SEQ_PAGE.rows_y + (voice_idx - 1) * SEQ_PAGE.row_spacing
      local selected = voice_idx == S.selected_voice
      -- the playing column: the voice's own sounding step (nil when
      -- stopped), the one every grid layout lights on its row
      local playing = S.lib.sequencer.sounding_step(voice_idx)
      local length = voice_length(voice_idx)
      screen.level(selected and SEQ_PAGE.selected_label_level or SEQ_PAGE.label_level)
      screen.move(SEQ_PAGE.label_x, y + SEQ_PAGE.text_offset)
      screen.text(tostring(voice_idx))
      for step = 1, PATTERN_LENGTH do
        local x = SEQ_PAGE.cells_x + (step - 1) * SEQ_PAGE.cell_spacing
        if step > length then
          draw_dot(x, y)
        else
          draw_cell(x, y, S.patterns[voice_idx][step], step == playing, SEQ_PAGE.cell_size)
        end
      end
      screen.level(SEQ_PAGE.label_level)
      if gated(voice_idx) then
        screen.move(SEQ_PAGE.gate_right, y + SEQ_PAGE.text_offset)
        screen.text_right(SEQ_PAGE.gate_mark)
      end
      screen.move(SEQ_PAGE.state_right, y + SEQ_PAGE.text_offset)
      screen.text_right(S.voices[voice_idx].active and "+" or "-")
    end

    -- the cursor: a 6x6 outline around the selected voice's step
    local cursor_y = SEQ_PAGE.rows_y + (S.selected_voice - 1) * SEQ_PAGE.row_spacing
    screen.level(SEQ_PAGE.cursor_level)
    screen.rect(SEQ_PAGE.cells_x + (cursor_step() - 1) * SEQ_PAGE.cell_spacing - 1, cursor_y - 1,
      SEQ_PAGE.cell_size + 2, SEQ_PAGE.cell_size + 2)
    screen.stroke()
  end

  -- Step attributes -------------------------------------------------------

  -- Whether a voice has a set bookmark (its bookmark row and ring show)
  function M.has_bookmarks(voice_idx)
    for n = 1, NUM_BOOKMARKS do
      if S.lib.bookmarks.is_set(voice_idx, n) then return true end
    end
    return false
  end

  -- A continuous lock's param name after "v<i>_": a step lock's from the
  -- sequencer's SEQ.lock_params, a step's gate STEP_GATE_PARAM; nil for any
  -- other key
  local function lock_param_name(key)
    if key == "gate" then return STEP_GATE_PARAM end
    return S.lib.sequencer.SEQ.lock_params[key]
  end

  -- The param a continuous lock (pos, pitch, size, a step's gate) moves on,
  -- or nil for any other key
  function M.lock_param_id(voice_idx, key)
    local name = lock_param_name(key)
    return name and voice_param_id(voice_idx, name)
  end

  -- What a step holds for key: its level, notes[1] for "notes", else the
  -- attribute (nil while off)
  local function step_value(voice_idx, step, key, index)
    if key == "level" then return S.patterns[voice_idx][step] end
    local value = S.lib.sequencer.step_attr(voice_idx, step, key)
    if key == "notes" then return value and value[index or 1] end
    return value
  end

  -- A step's notes list as text, to tell whether a turn changed any note
  local function notes_signature(voice_idx, step)
    local notes = S.lib.sequencer.step_attr(voice_idx, step, "notes")
    return notes and table.concat(notes, ",") or ""
  end

  -- Per "<voice>:<step>:<key>": the raw place (0-1 on its param's
  -- controlspec) a continuous lock was last turned to, so turns finer than
  -- the spec's step add up, as a control param's raw does. Used while the
  -- lock still holds the value it maps to; at most one per voice, step and
  -- lock
  local lock_raws = {}

  -- A continuous lock turned by raw_delta: from off it starts at the stored
  -- value; a turn below the range's start lands on the start, and one from
  -- the start goes off (nil); it never passes the range's end
  local function turned_lock(voice_idx, step, key, raw_delta)
    local param_id = M.lock_param_id(voice_idx, key)
    local spec = params:lookup_param(param_id).controlspec
    local current = S.lib.sequencer.step_attr(voice_idx, step, key)
    local carry = voice_idx .. ":" .. step .. ":" .. key
    local raw
    if current == nil then
      raw = spec:unmap(params:get(param_id))
    else
      raw = lock_raws[carry]
      if raw == nil or spec:map(raw) ~= current then raw = spec:unmap(current) end
    end
    local new_raw = raw + raw_delta
    if new_raw < 0 then
      if current == nil or raw <= 0 then
        lock_raws[carry] = nil
        return nil
      end
      new_raw = 0
    end
    new_raw = math.min(new_raw, 1)
    lock_raws[carry] = new_raw
    return spec:map(new_raw)
  end

  -- A whole value that can be off (a note, a bookmark) moved d steps: from
  -- off it starts at start; below low it lands on low, and from low it goes
  -- off; it stops at high
  local function turned_optional(current, start, low, high, d)
    local value = (current == nil and start or current) + d
    if value < low then
      if current ~= nil and current > low then return low end
      return nil
    end
    return math.min(value, high)
  end

  -- Note index of a step's chord turned by d (design 9.4): index 1..n moves
  -- that note (below -max_degree it is removed and the gap closes; the
  -- list left empty is nil); index n + 1 appends a note at the last note's
  -- degree turned d - 1 steps (d when d < 0), nothing when the chord is
  -- full or d is 0; from no notes, index 1 starts a note at 0
  local function turn_note(voice_idx, step, d, index)
    local SEQ = S.lib.sequencer.SEQ
    local notes = S.lib.sequencer.step_attr(voice_idx, step, "notes") or {}
    local count = #notes
    if index < 1 or index > count + 1 or index > SEQ.max_step_notes then return end
    if count > 0 and index == count + 1 then
      if d == 0 then return end
      local degree = notes[count] + (d > 0 and d - 1 or d)
      if degree < -SEQ.max_degree then return end
      notes[index] = math.min(degree, SEQ.max_degree)
    else
      local turned = turned_optional(notes[index], 0, -SEQ.max_degree, SEQ.max_degree, d)
      if turned == nil then table.remove(notes, index) else notes[index] = turned end
    end
    S.lib.sequencer.set_step_attr(voice_idx, step, "notes", #notes > 0 and notes or nil)
  end

  -- The step editor, while it is open: {voice, step, port, alt_k2_at (the
  -- time ALT+K2 went down on it, until its release)}
  local editor = nil

  -- True exactly while an action of the open step editor runs a pattern
  -- replacement (ruling 71): the grids read it (step_editor_replacing) in
  -- end_step_gestures, so the editor's own euclid, clear and randomize keep
  -- it open while a replacement from anywhere else closes it
  local replacing = false

  -- Turn voice's step's key by d whole steps ("level", "prob", "ratchet",
  -- "notes", "bookmark"), or a continuous lock ("pos", "pitch", "size",
  -- "gate") by d detents of its param's quantum (opts.fine: a tenth of it)
  -- or, with opts.raw, by that much of its range (the arc). Locks and notes
  -- from off start at the stored value or 0 (turned_lock, turned_optional);
  -- prob nil is 100 % and ratchet nil one hit, so either at that value is
  -- nil. The edit view's E3 and the step editor's rings both edit here.
  -- Returns whether the step changed
  function M.turn_step(voice_idx, step, key, d, opts)
    if not valid_place(voice_idx, step) then return false end
    opts = opts or {}
    local seq = S.lib.sequencer
    local SEQ = seq.SEQ
    local before = step_value(voice_idx, step, key)
    local notes_before = key == "notes" and notes_signature(voice_idx, step)
    if key == "level" then
      local pattern = S.patterns[voice_idx]
      pattern[step] = util.clamp(pattern[step] + d, 0, MAX_STEP_LEVEL)
      S.lib.mutation.note_pattern_edit(voice_idx)
      grid_redraw()
    elseif key == "prob" then
      local prob = util.clamp((before or SEQ.max_prob) + d, 0, SEQ.max_prob)
      seq.set_step_attr(voice_idx, step, key, prob < SEQ.max_prob and prob or nil)
    elseif key == "ratchet" then
      local hits = util.clamp((before or 1) + d, 1, SEQ.max_ratchet)
      seq.set_step_attr(voice_idx, step, key, hits > 1 and hits or nil)
    elseif key == "notes" then
      turn_note(voice_idx, step, d, opts.index or 1)
      return notes_signature(voice_idx, step) ~= notes_before
    elseif key == "bookmark" then
      if not M.has_bookmarks(voice_idx) then return false end
      seq.set_step_attr(voice_idx, step, key, turned_optional(before, 0, 1, NUM_BOOKMARKS, d))
    elseif lock_param_name(key) then
      local raw_delta = opts.raw
      if raw_delta == nil then
        local spec = params:lookup_param(M.lock_param_id(voice_idx, key)).controlspec
        raw_delta = d * spec.quantum / (opts.fine and FINE_DIVISOR or 1)
      end
      seq.set_step_attr(voice_idx, step, key, turned_lock(voice_idx, step, key, raw_delta))
    else
      return false
    end
    return step_value(voice_idx, step, key) ~= before
  end

  -- The edit view ----------------------------------------------------------

  -- The rows for a voice and step: field_list rows ({label, selectable,
  -- section}, a field's param_id resolved), each field with its EDIT_ROWS
  -- entry as spec
  local function edit_rows(voice_idx, step)
    local rows, section = {}, nil
    local bookmarks = M.has_bookmarks(voice_idx)
    for _, spec in ipairs(EDIT_ROWS) do
      if spec.section then
        section = spec.section
        rows[#rows + 1] = {label = section == "step" and ("step " .. step) or section, selectable = false,
          section = section}
      elseif spec.chord then
        local notes = S.lib.sequencer.step_attr(voice_idx, step, "notes")
        local count = notes and #notes or 0
        for index = 1, math.max(count, 1) do
          rows[#rows + 1] = {label = note_spec(index).label, section = section, spec = note_spec(index)}
        end
        if count >= 1 and count < S.lib.sequencer.SEQ.max_step_notes then
          rows[#rows + 1] = {label = NOTE_ADD_SPEC.label, section = section, spec = NOTE_ADD_SPEC}
        end
      elseif spec.row ~= "bookmark" or bookmarks then
        local param_id = spec.param_id or (spec.voice_param and voice_param_id(voice_idx, spec.voice_param))
        rows[#rows + 1] = {label = spec.label, section = section, param_id = param_id, spec = spec}
      end
    end
    return rows
  end

  -- The two places the edit view shows: SEQ's own (the selected voice at
  -- S.cursors.seq_step) and the step editor (its voice and step). Each
  -- keeps its cursor as an anchor, the row key it was put on and its index,
  -- so a row that comes or goes (bookmark) never moves it to another row
  local views = {
    page = {anchor = {row = SEQ_EDIT.first_key, index = 2}},
    editor = {anchor = {row = SEQ_EDIT.editor_first_key, index = 2}},
  }

  local function view_place(view)
    if view == views.editor then return editor.voice, editor.step end
    return S.selected_voice, cursor_step()
  end

  -- Run fn, a pattern replacement (a euclid fill, a clear, a randomize or
  -- its undo), as one of view's actions: for the step editor with replacing
  -- set around it, set back even when fn raises (the error is raised again)
  local function run_replacement(view, fn)
    if view ~= views.editor then return fn() end
    replacing = true
    local ran, problem = xpcall(fn, with_traceback)
    replacing = false
    if not ran then error(problem, 0) end
  end

  -- The view's rows and its cursor on them (the anchored row, or the
  -- nearest selectable one at or before the anchored index)
  local function sync_view(view)
    local rows = edit_rows(view_place(view))
    for index, row in ipairs(rows) do
      if row.spec and row.spec.row == view.anchor.row then return rows, index end
    end
    if view.anchor.row:match("^note%d?$") then
      -- a note row that is gone (its note removed, or a step with fewer
      -- notes): the last note row
      local last
      for index, row in ipairs(rows) do
        if row.spec and row.spec.attr == "notes" and not row.spec.add then last = index end
      end
      if last then return rows, last end
    end
    return rows, field_list.clamp(rows, view.anchor.index)
  end

  local function place_view(view, index)
    local rows = edit_rows(view_place(view))
    index = field_list.clamp(rows, index)
    view.anchor = {row = rows[index].spec.row, index = index}
  end

  local function move_view(view, d)
    local rows, cursor = sync_view(view)
    place_view(view, field_list.move(rows, cursor, d))
  end

  local function whole_text(value) return string.format("%d", math.floor(value + 0.5)) end

  -- A row's value as drawn ("" for the clear row)
  local function row_text(voice_idx, step, row)
    local spec = row.spec
    if spec.binary then return params:get(row.param_id) == 1 and "on" or "off" end
    if row.param_id then
      if spec.format == "%d" or spec.format == "%d%%" then
        return whole_text(params:get(row.param_id)) .. (spec.format == "%d%%" and "%" or "")
      end
      if spec.format then return string.format(spec.format, params:get(row.param_id)) end
      return (params:string(row.param_id):gsub("%s+$", ""))
    end
    if spec.row == "clear" then return "" end
    if spec.row == "euclid" then
      local fill = S.seq_euclid[voice_idx]
      if fill == nil then return "-" end
      return fill[1] .. "/" .. whole_text(voice_length(voice_idx)) .. " +" .. fill[2]
    end
    local SEQ = S.lib.sequencer.SEQ
    if spec.add then return "" end
    local value = step_value(voice_idx, step, spec.attr, spec.index)
    if spec.attr == "level" then return tostring(value) end
    if spec.attr == "prob" then return whole_text(value or SEQ.max_prob) .. "%" end
    if spec.attr == "ratchet" then return "x" .. whole_text(value or 1) end
    if value == nil then return "off" end
    if spec.attr == "notes" then return (value > 0 and "+" or "") .. whole_text(value) end
    if spec.attr == "bookmark" then return whole_text(value) end
    return string.format(ATTR_FORMATS[spec.attr], value)
  end

  local function draw_edit_row(voice_idx, step, row, y, selected)
    if row.selectable == false then
      screen.level(SEQ_EDIT.section_level)
      screen.move(SEQ_EDIT.section_x, y)
      screen.text(row.label)
      return
    end
    screen.level(selected and SEQ_EDIT.selected_level or SEQ_EDIT.field_level)
    screen.move(SEQ_EDIT.field_x, y)
    screen.text(row.label)
    local text = row_text(voice_idx, step, row)
    if text == "" then return end
    local room = SEQ_EDIT.value_right - (SEQ_EDIT.field_x + screen.text_extents(row.label)) - SEQ_EDIT.value_gap
    screen.move(SEQ_EDIT.value_right, y)
    screen.text_right(fit_text(text, room))
  end

  -- The line under the header: the voice and step, and the voice's sixteen
  -- steps (past its length as dots, the playing one brighter, the step
  -- outlined)
  local function draw_edit_line(voice_idx, step)
    screen.level(SEQ_EDIT.line_level)
    screen.move(0, SEQ_EDIT.line_y)
    screen.text("v" .. voice_idx .. " step " .. step)
    local length = voice_length(voice_idx)
    local playing = S.lib.sequencer.sounding_step(voice_idx)
    for cell = 1, PATTERN_LENGTH do
      local x = SEQ_EDIT.strip_x + (cell - 1) * SEQ_EDIT.strip_spacing
      if cell > length then
        draw_dot(x, SEQ_EDIT.strip_y)
      else
        draw_cell(x, SEQ_EDIT.strip_y, S.patterns[voice_idx][cell], cell == playing, SEQ_EDIT.strip_cell)
      end
    end
    screen.level(SEQ_PAGE.cursor_level)
    screen.rect(SEQ_EDIT.strip_x + (step - 1) * SEQ_EDIT.strip_spacing - 1, SEQ_EDIT.strip_y - 1,
      SEQ_EDIT.strip_cell + 2, SEQ_EDIT.strip_cell + 2)
    screen.stroke()
  end

  local function draw_edit_view(view)
    local voice_idx, step = view_place(view)
    local rows, cursor = sync_view(view)
    draw_edit_line(voice_idx, step)
    field_list.draw(rows, cursor, {visible = SEQ_EDIT.visible, first_y = SEQ_EDIT.first_y,
      spacing = SEQ_EDIT.spacing, value_right = SEQ_EDIT.value_right},
      function(row, y, selected) draw_edit_row(voice_idx, step, row, y, selected) end)
  end

  -- The Euclidean fill (design 8.5) moved by hits and rotation steps from
  -- the voice's last (none: 0 hits, no rotation)
  local function turn_euclid(voice_idx, hits_d, rotation_d)
    local fill = S.seq_euclid[voice_idx] or {0, 0}
    local hits = util.clamp(fill[1] + hits_d, 0, voice_length(voice_idx))
    S.lib.sequencer.euclid(voice_idx, hits, fill[2] + rotation_d)
  end

  -- E3 on view's row (ALT+E3: fine on a control row, the rotation on
  -- euclid; a whole-number row steps as E3 does)
  local function turn_row(view, voice_idx, step, row, d)
    local spec = row.spec
    if spec.row == "euclid" then
      run_replacement(view, function()
        if S.alt_held then turn_euclid(voice_idx, 0, d) else turn_euclid(voice_idx, d, 0) end
      end)
    elseif spec.binary then
      -- on with a turn up, off with a turn down, as VOICE's binary rows
      set_binary_param(row.param_id, d > 0 and 1 or 0)
    elseif row.param_id then
      enc_param_delta(3, row.param_id, d)
    elseif spec.attr == "notes" then
      local notes = S.lib.sequencer.step_attr(voice_idx, step, "notes")
      local count = notes and #notes or 0
      M.turn_step(voice_idx, step, "notes", d, {fine = S.alt_held, index = spec.add and count + 1 or spec.index})
      local after = S.lib.sequencer.step_attr(voice_idx, step, "notes")
      if spec.add and after and #after > count then
        -- the cursor moves to the note just added
        for index, row in ipairs(edit_rows(voice_idx, step)) do
          if row.spec == note_spec(#after) then place_view(view, index) end
        end
      else
        place_view(view, select(2, sync_view(view)))
      end
    elseif spec.attr then
      M.turn_step(voice_idx, step, spec.attr, d, {fine = S.alt_held})
    end
  end

  -- E2 the row, E3 its value; with ALT, E2 the step (SEQ's ALT+E2 goes
  -- through seq_alt_enc)
  local function edit_enc(view, n, d)
    if n == 2 then
      move_view(view, d)
    elseif n == 3 then
      local voice_idx, step = view_place(view)
      local rows, cursor = sync_view(view)
      turn_row(view, voice_idx, step, rows[cursor], d)
    end
  end

  -- K3: the step on or off; on the clear row, the pattern cleared
  local function edit_k3(view)
    local voice_idx, step = view_place(view)
    local rows, cursor = sync_view(view)
    if rows[cursor].spec.row == "clear" then
      run_replacement(view, function() clear_pattern(voice_idx) end)
    else
      toggle_pattern_step(voice_idx, step)
    end
    pattern_changed()
  end

  -- ALT+K2 held, the view's alt_hold: the row back to its default (a lock,
  -- a note, a step's gate or bookmark off, prob 100 %, one hit, the level
  -- 0, a param its default); euclid and clear keep everything
  local function reset_row(view)
    local voice_idx, step = view_place(view)
    local rows, cursor = sync_view(view)
    local row = rows[cursor]
    local spec = row.spec
    if spec.binary then
      set_binary_param(row.param_id, param_default(row.param_id))  -- echoes to a MIDI map (#519)
    elseif row.param_id then
      params:set(row.param_id, param_default(row.param_id))
    elseif spec.attr == "level" then
      S.patterns[voice_idx][step] = 0
      S.lib.mutation.note_pattern_edit(voice_idx)
    elseif spec.attr == "notes" then
      -- a note row removes that note (the add row has nothing to reset)
      if spec.index then
        local notes = S.lib.sequencer.step_attr(voice_idx, step, "notes") or {}
        table.remove(notes, spec.index)
        S.lib.sequencer.set_step_attr(voice_idx, step, "notes", #notes > 0 and notes or nil)
        place_view(view, select(2, sync_view(view)))
      end
    elseif spec.attr then
      S.lib.sequencer.set_step_attr(voice_idx, step, spec.attr, nil)
    end
    pattern_changed()
  end

  -- Whether reset_row has a default to put the view's row back to: every
  -- row but euclid and clear (#596: the held hint names the reset only
  -- where letting go resets; elsewhere it cancels the quick press)
  local function row_resets(view)
    local rows, cursor = sync_view(view)
    local row = rows[cursor]
    return row.param_id ~= nil or (row.spec.attr ~= nil and not row.spec.add)
  end

  -- The note index the step editor's cursor is on (1 off the note rows and
  -- on the add row): what its arc ring turns (design 9.4)
  function M.editor_note_index()
    if editor == nil then return 1 end
    local rows, cursor = sync_view(views.editor)
    local spec = rows[cursor].spec
    return spec.attr == "notes" and spec.index or 1
  end

  -- The edit view's hints: k2_text is ALT+K2's (what letting go does) and
  -- k2_down whether it is held (K1 let go first: its hint alone)
  local function edit_hints(view, alt_held, k2_text, k2_down)
    if alt_held then return k2_text .. " K3:clr E2:step" end
    if k2_down then return k2_text end
    local rows, cursor = sync_view(view)
    local row = rows[cursor]
    if row.spec.row == "clear" then return "K2:back K3:clr" end
    return "K2:back K3:step E3:" .. row.label
  end

  -- The page --------------------------------------------------------------

  -- Whether SEQ shows its edit view (else the pattern view)
  local edit_open = false

  local function seq_record() return S.registry.pages[UI_PAGES.index.SEQ] end

  local function redraw_seq()
    if edit_open then draw_edit_view(views.page) else redraw_pattern_view() end
  end

  -- The hint row (redraw() draws it after the page). K1 let go while
  -- ALT+K2 is down: K2's hint alone, since its release still acts
  local function seq_hints(alt_held)
    local record = seq_record()
    if edit_open then
      return edit_hints(views.page, alt_held, S.lib.ui_alt.k2_hint(record), S.lib.ui_alt.k2_held())
    end
    if alt_held then return S.lib.ui_alt.k2_hint(record) .. " K3:clr E3:bpm" end
    if S.lib.ui_alt.k2_held() then return S.lib.ui_alt.k2_hint(record) end
    return "K2:" .. (S.pattern_playing and "stop" or "play") .. " K3:step E3:level"
  end

  local function seq_enc(n, d)
    if edit_open then return edit_enc(views.page, n, d) end
    if n == 2 then
      S.lib.ui_cursors.move("seq_step", d)
    elseif n == 3 then
      local pattern, step = S.patterns[S.selected_voice], cursor_step()
      if not pattern then return end
      pattern[step] = util.clamp(pattern[step] + d, 0, MAX_STEP_LEVEL)
      S.lib.mutation.note_pattern_edit(S.selected_voice)
      pattern_changed()
    end
  end

  -- ALT+E2: another voice's row (the selected voice, as on MAIN), in the
  -- edit view the step; ALT+E3: the tempo (a number param, so whole BPM:
  -- patterns are not params and have nothing to adjust finely), in the
  -- edit view not handled here (seq_enc's E3 reads ALT: fine, rotation)
  local function seq_alt_enc(n, d)
    if n == 2 then
      if edit_open then S.lib.ui_cursors.move("seq_step", d) else S.lib.ui_keys.select_voice_by(d) end
      return true
    elseif n == 3 and not edit_open then
      enc_param_delta(n, "tempo", d)
      return true
    end
    return false
  end

  local function seq_key(n)
    if edit_open then
      if n == 2 then edit_open = false elseif n == 3 then edit_k3(views.page) end
      return
    end
    if n == 2 then
      pattern_toggle()
    elseif n == 3 then
      toggle_pattern_step(S.selected_voice, cursor_step())
      pattern_changed()
    end
  end

  -- What ALT+K2 randomizes (S.lib.ui_alt.k2_up), in both views: the
  -- selected voice's pattern, levels only (lock covers params, not
  -- patterns, so never "locked")
  local function pattern_spec(voice_idx)
    return {page = UI_PAGES.index.SEQ, section = "pattern", voice = voice_idx, pattern = voice_idx}
  end

  local function seq_randomize_section()
    return pattern_spec(S.selected_voice)
  end

  -- ALT+K2 (through alt_action) only notes its press: it acts on release.
  -- ALT+K3 clears the selected voice's pattern
  local function seq_alt_key(n)
    if n == 2 then
      S.lib.ui_alt.k2_down()
    elseif n == 3 then
      clear_pattern(S.selected_voice)
      pattern_changed()
    end
  end

  -- ALT+K2 released: a quick press undoes or randomizes the pattern (the
  -- grid follows); one held past the hold time runs seq_alt_hold
  local function seq_alt_key_release(n)
    if n == 2 then
      S.lib.ui_alt.k2_up(seq_record())
      pattern_changed()
    end
  end

  -- ALT+K2 held: the pattern view opens the edit view (Question 12); the
  -- edit view resets the cursor's row. The hint names it (alt_hold_hint):
  -- cancel on a row with nothing to reset
  local function seq_alt_hold()
    if edit_open then reset_row(views.page) else edit_open = true end
  end

  local function seq_alt_hold_hint()
    if not edit_open then return "edit" end
    return row_resets(views.page) and "reset" or "cancel"
  end

  -- The tempo replaces the header's indicators (the play mark stays)
  local function seq_header_status()
    return string.format("%d bpm", math.floor(params:get("tempo") + 0.5))
  end

  -- The arc button plays and stops the patterns (design §7)
  local function seq_arc_button()
    pattern_toggle()
  end

  -- The step editor -------------------------------------------------------

  -- What its ALT+K2 does, through S.lib.ui_alt's k2_down and k2_up (a quick
  -- press randomizes the editor's voice's pattern or undoes it, a hold
  -- resets the row), as SEQ's record does
  local editor_alt = {
    randomize_section = function() return pattern_spec(editor.voice) end,
    alt_hold = function() reset_row(views.editor) end,
  }

  local editor_owner

  -- ALT+E2 its step; E2 and E3 as the edit view's
  local function editor_enc(n, d)
    if editor == nil then return end
    if n == 2 and S.alt_held then
      editor.step = util.clamp(editor.step + d, 1, PATTERN_LENGTH)
    else
      edit_enc(views.editor, n, d)
    end
  end

  -- K2 closes the editor (the page shows again), K3 the step on or off (on
  -- the clear row, clears); ALT+K2 on release, ALT+K3 clears the editor's
  -- voice's pattern
  local function editor_key(n, z)
    if editor == nil then return end
    if n == 2 then
      if z == 1 and S.alt_held then
        editor.alt_k2_at = util.time()
        S.lib.ui_alt.k2_down()
      elseif z == 1 then
        M.close_step_editor(editor.port)
      elseif editor.alt_k2_at then
        editor.alt_k2_at = nil
        run_replacement(views.editor, function() S.lib.ui_alt.k2_up(editor_alt) end)
        pattern_changed()
      end
    elseif n == 3 and z == 1 then
      if S.alt_held then
        local voice_idx = editor.voice
        run_replacement(views.editor, function() clear_pattern(voice_idx) end)
        pattern_changed()
      else
        edit_k3(views.editor)
      end
    end
  end

  -- The editor's ALT+K2 hint: reset once held ALT_HOLD_SECONDS (cancel on
  -- a row with nothing to reset), else the quick press's (rand or undo).
  -- The owner animates while ALT+K2 is held (#592), so the frame clock
  -- draws the change at the hold time
  local function editor_k2_text()
    if editor.alt_k2_at and util.time() - editor.alt_k2_at >= ALT_HOLD_SECONDS then
      return row_resets(views.editor) and "K2:reset" or "K2:cancel"
    end
    return S.lib.ui_alt.k2_hint(editor_alt)
  end

  -- The frame clock draws every frame while it is true (lib/ui/frame.lua):
  -- while ALT+K2 is held on the editor (its hint turns at the hold time) or
  -- the patterns play (its strip's playhead moves), over any page
  local function editor_animates()
    return editor ~= nil and (editor.alt_k2_at ~= nil or S.pattern_playing)
  end

  -- The norns menu takes every key while it is open, so an ALT+K2 release
  -- made there never reaches the editor: its press is forgotten as the menu
  -- closes, or the owner would animate and its hint stay K2:reset until it
  -- closed. (SEQ's own view needs nothing here: its hint and animates read
  -- S.lib.ui_alt.k2_held(), whose press marks the menu's opening forgets)
  function M.forget_editor_k2_press()
    if editor then editor.alt_k2_at = nil end
  end
  S.register_menu_close(function() M.forget_editor_k2_press() end)

  editor_owner = {
    draw = function() if editor then draw_edit_view(views.editor) end end,
    hints = function(alt_held)
      if editor == nil then return "" end
      return edit_hints(views.editor, alt_held, editor_k2_text(), editor.alt_k2_at ~= nil)
    end,
    enc = editor_enc,
    key = editor_key,
    animates = editor_animates,
  }
  -- lib/arc/seq.lua sets its ring fields (arc_delta, arc_redraw)
  M.step_editor_owner = editor_owner

  -- Open the step editor (design 8.7) for voice's step, from grid port:
  -- the edit view pushed as a modal owner, so it shows over any page and
  -- takes E2, E3, K2, K3 and the arc. A second open replaces the first
  -- (another port's included). Every ring's carried ticks are forgotten,
  -- as at a page change. Returns true, or false (opening nothing) for a
  -- voice or step out of range
  function M.open_step_editor(voice_idx, step, port)
    if not valid_place(voice_idx, step) then return false end
    if editor then S.lib.ui_modal.pop(editor_owner) end
    editor = {voice = voice_idx, step = step, port = port}
    forget_arc_ticks()
    S.lib.ui_modal.push(editor_owner)
    return true
  end

  -- Close the step editor port opened (an editor another port opened
  -- since stays): the page shows again
  function M.close_step_editor(port)
    if editor == nil or editor.port ~= port then return end
    editor = nil
    forget_arc_ticks()
    S.lib.ui_modal.pop(editor_owner)
  end

  -- {voice, step, port} of the open step editor (a copy), or nil
  function M.step_editor()
    if editor == nil then return nil end
    return {voice = editor.voice, step = editor.step, port = editor.port}
  end

  -- Whether an action of the open step editor is running a pattern
  -- replacement now (its euclid, clear, ALT+K3, ALT+K2's randomize or
  -- undo; ruling 71): the grids keep the editor open through those and
  -- close it at any other replacement. False with no editor open
  function M.step_editor_replacing()
    return editor ~= nil and replacing
  end

  -- The editor is open exactly while its owner is the modal one
  S.register_invariant("step editor", function()
    local pushed = S.lib.ui_modal.top() == editor_owner
    if (editor ~= nil) ~= pushed then
      return "the step editor is " .. (editor and "open" or "closed") .. " but its owner is "
        .. (pushed and "" or "not ") .. "pushed"
    end
  end)

  -- Layout states ---------------------------------------------------------

  -- Extra states for the layout tests and the page renders
  local function show_cursor(voice_idx, step)
    return function()
      S.lib.ui_keys.select_voice_by(voice_idx - S.selected_voice)
      S.cursors.seq_step = step
    end
  end

  -- Every row of a voice's step at its widest value, its slot holding audio
  -- (so its bookmarks are set) or not
  local function widest_values(voice_idx, step, bookmarks)
    local seq = S.lib.sequencer
    local SEQ = seq.SEQ
    local function set(name, value) params:set(voice_param_id(voice_idx, name), value) end
    if bookmarks then
      S.buffers[1].seconds = S.performance.buffer_seconds
      set("source", S.constants.SOURCE_SYNTH + 1)
    end
    set("seq_division", 2)               -- 1/16t
    set("seq_swing", SEQ.swing[2])
    set("seq_gate_length", SEQ.gate_steps[2])
    set("seq_gate_release", SEQ.gate_release[2])
    seq.euclid(voice_idx, PATTERN_LENGTH, PATTERN_LENGTH - 1)
    seq.set_step_attr(voice_idx, step, "prob", SEQ.max_prob)
    seq.set_step_attr(voice_idx, step, "ratchet", SEQ.max_ratchet)
    seq.set_step_attr(voice_idx, step, "gate", SEQ.gate_steps[2])
    seq.set_step_attr(voice_idx, step, "notes", {-SEQ.max_degree})
    seq.set_step_attr(voice_idx, step, "pos", 0.88)  -- "0.88": no narrow 1 in it
    seq.set_step_attr(voice_idx, step, "pitch", 4)
    seq.set_step_attr(voice_idx, step, "size", 0.5)
    params:set("seq_chain_from", S.constants.NUM_SCENES)
    params:set("seq_chain_scenes", S.constants.NUM_SCENES)
    params:set("seq_chain_bars", SEQ.max_chain_bars)
    params:set("quantize_actions", 2)    -- beat
  end

  -- The edit view on voice_idx's step, its cursor so that the view shows
  -- rows (window - 1) * visible + 1 on (the last window: the last rows)
  local function edit_state(voice_idx, step, bookmarks, window)
    return {
      name = string.format("edit view v%d step %d%s rows %d", voice_idx, step, bookmarks and " bookmarks" or "", window),
      setup = function()
        show_cursor(voice_idx, step)()
        widest_values(voice_idx, step, bookmarks)
        edit_open = true
        place_view(views.page, (window - 1) * SEQ_EDIT.visible + 2)
      end,
    }
  end

  -- A step with the most notes, every one at its widest (-14)
  local function eight_notes(voice_idx, step)
    local SEQ = S.lib.sequencer.SEQ
    local notes = {}
    for index = 1, SEQ.max_step_notes do notes[index] = -SEQ.max_degree end
    S.lib.sequencer.set_step_attr(voice_idx, step, "notes", notes)
  end

  local layout_states = {
    {name = "cursor-v1-s1", setup = show_cursor(1, 1)},
    {name = "cursor-v1-s16", setup = show_cursor(1, PATTERN_LENGTH)},
    {name = "cursor-v7-s1", setup = show_cursor(NUM_VOICES, 1)},
    {name = "cursor-v7-s16", setup = show_cursor(NUM_VOICES, PATTERN_LENGTH)},
    {name = "levels-playing", setup = function(context)
      for voice_idx = 1, NUM_VOICES do
        local steps = {}
        for step = 1, PATTERN_LENGTH do
          steps[step] = (voice_idx + step) % 3 == 0 and (voice_idx * step) % (MAX_STEP_LEVEL + 1) or 0
        end
        S.lib.sequencer.replace_pattern(voice_idx, steps)
      end
      pattern_toggle()
      context.clock.run_for(0.5)
    end},
    {name = "tempo-300", setup = function()
      params:set("tempo", 300)
      pattern_toggle()
    end},
    -- 3.4: short voices, gated voices one under another, and their own
    -- playheads at three divisions
    {name = "short-gated-playing", setup = function(context)
      for voice_idx = 1, NUM_VOICES do
        params:set(voice_param_id(voice_idx, "seq_length"), voice_idx * 2)
        params:set(voice_param_id(voice_idx, "seq_division"), 2 + voice_idx % 3)
        if voice_idx <= 3 then params:set(voice_param_id(voice_idx, "seq_gate"), S.lib.sequencer.SEQ.gate_on) end
        for step = 1, PATTERN_LENGTH do S.patterns[voice_idx][step] = (voice_idx + step) % 4 == 0 and 12 or 0 end
      end
      show_cursor(NUM_VOICES, PATTERN_LENGTH)()
      pattern_toggle()
      context.clock.run_for(1.3)
    end},
    -- the pattern view's widest ALT hint: K2:edit K3:clr E3:bpm
    {name = "pattern view, ALT+K2 held: K2:edit", setup = function(context)
      key(1, 1); key(2, 1)
      context.clock.run_for(ALT_HOLD_SECONDS)
    end},
    -- the edit view's: K2:reset K3:clr E2:step
    {name = "ALT+K2 held past the hold time", setup = function(context)
      edit_open = true
      key(1, 1); key(2, 1)
      context.clock.run_for(ALT_HOLD_SECONDS)
    end},
    -- the step editor over SEQ, on voice 7's last step
    {name = "step editor v7 step 16", setup = function()
      widest_values(NUM_VOICES, PATTERN_LENGTH, true)
      M.open_step_editor(NUM_VOICES, PATTERN_LENGTH, 1)
    end},
    -- 3.5: a step with eight notes in the step editor, on its last note row
    {name = "a step with eight notes", setup = function()
      widest_values(NUM_VOICES, PATTERN_LENGTH, true)
      eight_notes(NUM_VOICES, PATTERN_LENGTH)
      M.open_step_editor(NUM_VOICES, PATTERN_LENGTH, 1)
      for index, row in ipairs(edit_rows(NUM_VOICES, PATTERN_LENGTH)) do
        if row.spec and row.spec.row == "note8" then place_view(views.editor, index) end
      end
    end},
  }
  -- the edit view with eight notes, every window of its rows
  for window = 1, 7 do
    table.insert(layout_states, {
      name = "edit view eight notes rows " .. window,
      setup = function()
        show_cursor(NUM_VOICES, PATTERN_LENGTH)()
        widest_values(NUM_VOICES, PATTERN_LENGTH, true)
        eight_notes(NUM_VOICES, PATTERN_LENGTH)
        edit_open = true
        place_view(views.page, (window - 1) * SEQ_EDIT.visible + 2)
      end,
    })
  end
  -- the edit view with every row at its widest value, on voices 1 and 7
  -- at step 16, with and without bookmarks, five windows each
  for _, voice_idx in ipairs({1, NUM_VOICES}) do
    for _, bookmarks in ipairs({false, true}) do
      for window = 1, SEQ_EDIT.visible do
        table.insert(layout_states, edit_state(voice_idx, PATTERN_LENGTH, bookmarks, window))
      end
    end
  end

  -- The page's record, at SEQ's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/seq.lua's
  S.registry.pages[UI_PAGES.index.SEQ] = {name = "SEQ", draw = redraw_seq, hints = seq_hints,
    enc = seq_enc, key = seq_key, alt_enc = seq_alt_enc, alt_key = seq_alt_key,
    alt_key_release = seq_alt_key_release, randomize_section = seq_randomize_section,
    alt_hold = seq_alt_hold, alt_hold_hint = seq_alt_hold_hint, header_status = seq_header_status,
    animates = function() return S.pattern_playing or S.lib.ui_alt.k2_held() end, arc_button = seq_arc_button,
    layout_states = layout_states}

  return M
end

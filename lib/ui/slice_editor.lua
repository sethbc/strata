-- lib/ui/slice_editor.lua
-- The slice editor (3.7, design §3.7), S.lib.ui_slice_editor: a modal
-- screen owner (S.lib.ui_modal) that K3 opens on BUFFER's slices field,
-- for the slot under BUFFER's cursor. Over the slot's waveform (its 64
-- points at 2 px) it shows a tick per marker, the slice that plays and the
-- selected voice's playhead; under it four lines of two fields, three in
-- view. Markers view (where it opens): E2 picks a marker, E3 nudges it
-- (ALT finely), K3 adds one at the playhead (else in the selected slice's
-- middle), ALT+K3 deletes it, ALT+E2 goes to the rows. Rows view: ALT+E2
-- picks a row (mode, amount, tempo, bars, key, norm), E3 edits it, E2
-- goes back to the markers. K2 closes. On the key row a MIDI note sets the
-- key. The slices are S.lib.slices', the file's settings S.lib.samples'
-- (read at each use: a build without them shows no slices and opens no
-- editor). lib/arc/buffer.lua sets the owner's ring fields; BUFFER's field
-- and waveform marks read slot_text and starts. Fields of this module's
-- table: EDITOR, open, close, is_open, state, ready, pick_marker,
-- pick_row, nudge, add, delete, turn_row, amount_range, ring_fractions,
-- slot_text, starts, owner. See docs/notes/lua/ui/slice-editor.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local field_list = S.lib.ui_field_list
  local musicutil = require "musicutil"

  -- The editor's tunables and layout. A nudge in seconds (E3, ALT+E3 and
  -- arc ring 2 a tick); the rows in their order; the bars the bars row
  -- steps over; the tempo row's step; the amount's ranges besides the
  -- slices' maximum; the short mode names BUFFER's field shows. layout: the
  -- title at title_y; the marker ticks tick_height px from tick_y, the
  -- playing slice's span on span_y; the waveform's points point_width px
  -- wide around wave_center (wave_half px each way at a peak of 1, inside
  -- wave_top to wave_bottom); three lines from first_y, spacing apart, the
  -- left field's label at left_x with its value right-aligned at
  -- left_right, the right field's from right_x to value_right (the scroll
  -- marker owns x 127); the seconds of a marker below seconds_coarse_from
  -- to the millisecond. levels: see draw. flashes: the hint row's texts
  local EDITOR = {
    nudge_seconds = 0.001,
    fine_nudge_seconds = 0.0001,
    rows = {"mode", "amount", "tempo", "bars", "key", "norm"},
    bars = {0.25, 0.5, 1, 2, 4, 8, 16, 32},
    bar_texts = {[0.25] = "1/4", [0.5] = "1/2"},
    tempo_step = 0.1,
    count_min = 2,
    sensitivity_max = 100,
    short_modes = {off = "off", equal = "eq", transients = "tran"},
    none_text = "--",
    layout = {title_y = 16, title_right = 127, tick_y = 18, tick_height = 3, span_y = 20,
      wave_top = 22, wave_bottom = 32, wave_center = 27, wave_half = 5, point_width = 2, screen_width = 128,
      first_y = 41, spacing = 7, visible = 3, left_x = 0, left_right = 68, right_x = 72, value_right = 124,
      seconds_coarse_from = 100},
    levels = {title = 15, title_right = 10, wave = 6, wave_empty = 1, tick = 6, selected_tick = 15, span = 12,
      head = 15, label = 3, value = 8, picked_label = 10, picked = 15},
    flashes = {full = "64 slices max", close = "too close", dropped = "edits dropped"},
  }
  M.EDITOR = EDITOR

  -- The lines under the waveform, two fields each; the markers view's cursor
  -- is the slice line, the rows view's the line of its row
  local LINES = {
    {fields = {"mode", "amount"}},
    {fields = {"slice", "at"}},
    {fields = {"tempo", "bars"}},
    {fields = {"key", "norm"}},
  }
  local MARKERS_LINE = 2
  local LINE_OF = {}
  for index, line in ipairs(LINES) do
    for _, name in ipairs(line.fields) do LINE_OF[name] = index end
  end

  -- open; its slot; the selected marker (1-based); the view ("markers" or
  -- "rows") and the picked row (an index into EDITOR.rows, kept closed)
  local editor = {open = false, slot = nil, marker = 1, view = "markers", row = 1}
  -- the note a MIDI note on the key row set, until the next clock step sets it
  local pending_key = nil
  -- the S.lib.samples its bind listener is registered with
  local bound_to = nil
  local owner

  ---------------------------------------------------------------------------
  -- What the slot holds (S.lib.slices, S.lib.samples, S.lib.waveforms)
  ---------------------------------------------------------------------------

  -- Whether the modules the editor reads are there
  function M.ready()
    return S.lib.slices ~= nil and S.lib.samples ~= nil and S.lib.waveforms.frames ~= nil
  end

  local function valid_slot(slot)
    return type(slot) == "number" and slot >= 1 and slot <= S.constants.NUM_BUFFERS and slot % 1 == 0
  end

  -- The settings record of what the slot holds, nil for no audio
  local function settings(slot)
    if not M.ready() or not valid_slot(slot) then return nil end
    return S.lib.samples.settings(slot)
  end

  -- The slot's markers, {0} when it has none
  local function markers(slot)
    local list = M.ready() and valid_slot(slot) and S.lib.slices.markers(slot)
    if type(list) ~= "table" or #list == 0 then return {0} end
    return list
  end

  local function frames(slot)
    return M.ready() and valid_slot(slot) and S.lib.waveforms.frames(slot) or nil
  end

  local function rate(slot)
    local waveforms = S.lib.waveforms
    return waveforms.rate and waveforms.rate(slot) or S.constants.NORNS_SAMPLE_RATE
  end

  local function mode_name(record)
    return S.lib.samples.SAMPLES.modes[record.mode] or "off"
  end

  local function round(value)
    if value < 0 then return -math.floor(-value + 0.5) end
    return math.floor(value + 0.5)
  end

  -- The selected marker, kept inside the list
  local function selected(list)
    editor.marker = util.clamp(editor.marker, 1, #list)
    return editor.marker
  end

  -- Select the marker nearest frame (a nudge or an add the slices refused
  -- or moved keeps the selection on the marker it meant)
  local function select_frame(frame)
    local list = markers(editor.slot)
    local nearest = math.huge
    for index, marker in ipairs(list) do
      if math.abs(marker - frame) < nearest then editor.marker, nearest = index, math.abs(marker - frame) end
    end
  end

  local function flash(text) buffer_page_flash(text) end

  ---------------------------------------------------------------------------
  -- Opening and closing
  ---------------------------------------------------------------------------

  -- The slot emptied under the editor closes it (S.lib.samples' bind
  -- listeners hear every bind and unbind); registered once with the store
  -- the first open finds
  local function listen_for_binds()
    local samples = S.lib.samples
    if bound_to == samples then return end
    bound_to = samples
    samples.on_bind(function(slot)
      if editor.open and slot == editor.slot and not settings(slot) then M.close() end
    end)
  end

  -- Open the editor on slot, in the markers view on its first marker: false
  -- (nothing opened) for a slot with no audio. A second open replaces the
  -- first; every ring's carried ticks are forgotten, as at a page change
  function M.open(slot)
    if not settings(slot) then return false end
    if editor.open then S.lib.ui_modal.pop(owner) end
    listen_for_binds()
    editor.open, editor.slot, editor.marker, editor.view = true, slot, 1, "markers"
    pending_key = nil
    forget_arc_ticks()
    S.lib.ui_modal.push(owner)
    return true
  end

  function M.close()
    if not editor.open then return end
    editor.open, pending_key = false, nil
    S.lib.ui_modal.pop(owner)
  end

  function M.is_open() return editor.open end

  -- {slot, marker, view, row (the picked row's name in the rows view)}, or nil
  function M.state()
    if not editor.open then return nil end
    return {slot = editor.slot, marker = editor.marker, view = editor.view,
      row = editor.view == "rows" and EDITOR.rows[editor.row] or nil}
  end

  ---------------------------------------------------------------------------
  -- The markers
  ---------------------------------------------------------------------------

  function M.pick_marker(d)
    if not editor.open then return end
    editor.marker = util.clamp(editor.marker + d, 1, #markers(editor.slot))
    request_redraw()
  end

  -- Nudge the selected marker d nudges (fine: ALT's), in whole frames at the
  -- slot's rate; the first marker never moves
  function M.nudge(d, fine)
    if not editor.open or d == 0 or not frames(editor.slot) then return end
    local slot = editor.slot
    local list = markers(slot)
    local index = selected(list)
    if index <= 1 then return end
    local by = round(d * (fine and EDITOR.fine_nudge_seconds or EDITOR.nudge_seconds) * rate(slot))
    if by == 0 then return end
    S.lib.slices.nudge_marker(slot, index, by)
    select_frame(list[index] + by)
    request_redraw()
  end

  -- Add a marker at the selected voice's playhead when it reads the slot and
  -- runs, else in the middle of the selected slice; the new one is
  -- selected. One that was not added flashes why
  function M.add()
    local slot = editor.slot
    local total = frames(slot)
    if not editor.open or not total then return end
    local before = markers(slot)
    local voice = S.selected_voice
    local position = voice_buffer_slot(voice) == slot and S.lib.playheads.position(voice) or nil
    local frame
    if position then
      frame = math.floor(position * total + 0.5)
    else
      local index = selected(before)
      frame = math.floor((before[index] + (before[index + 1] or total)) / 2)
    end
    frame = util.clamp(frame, 0, total - 1)
    S.lib.slices.add_marker(slot, frame)
    if #markers(slot) <= #before then
      flash(#before >= S.lib.slices.SLICES.max and EDITOR.flashes.full or EDITOR.flashes.close)
      return
    end
    select_frame(frame)
    request_redraw()
  end

  -- Delete the selected marker (never the first); the one before it is selected
  function M.delete()
    if not editor.open then return end
    local index = selected(markers(editor.slot))
    if index <= 1 then return end
    S.lib.slices.delete_marker(editor.slot, index)
    editor.marker = index - 1
    request_redraw()
  end

  ---------------------------------------------------------------------------
  -- The rows
  ---------------------------------------------------------------------------

  function M.pick_row(name)
    if not editor.open then return end
    for index, row in ipairs(EDITOR.rows) do
      if row == name then editor.row, editor.view = index, "rows" end
    end
    request_redraw()
  end

  -- The amount's range for the record's mode: the sensitivity's in
  -- transients, else the count's
  function M.amount_range(record)
    record = record or settings(editor.slot)
    if record and mode_name(record) == "transients" then return 0, EDITOR.sensitivity_max end
    return EDITOR.count_min, S.lib.slices.SLICES.max
  end

  -- A change that makes the slices again (the mode, the amount): a record
  -- edited by hand says its edits went
  local function remake(slot, record, field, value)
    local edited = record.edited
    S.lib.samples.set(slot, field, value)
    S.lib.slices.make(slot)
    if edited then flash(EDITOR.flashes.dropped) end
  end

  local function round_tempo(tempo)
    return math.floor(tempo / EDITOR.tempo_step + 0.5) * EDITOR.tempo_step
  end

  -- From no tempo a turn up starts at the clock's; below the lowest it clears
  local function turn_tempo(slot, record, d)
    local SAMPLES = S.lib.samples.SAMPLES
    local tempo
    if record.tempo == nil then
      if d <= 0 then return end
      tempo = util.clamp(round_tempo(clock.get_tempo()), SAMPLES.tempo_min, SAMPLES.tempo_max)
    else
      tempo = round_tempo(record.tempo + d * EDITOR.tempo_step)
      if tempo < SAMPLES.tempo_min then tempo = nil else tempo = math.min(tempo, SAMPLES.tempo_max) end
    end
    if tempo ~= record.tempo then S.lib.samples.set(slot, "tempo", tempo) end
  end

  -- Each step goes to the next bars count in its direction that set_bars
  -- takes (a count whose tempo is out of range is passed over); none: stop
  local function turn_bars(slot, d)
    local direction = d > 0 and 1 or -1
    local first, last = 1, #EDITOR.bars
    if direction < 0 then first, last = last, first end
    for _ = 1, math.abs(d) do
      local current = S.lib.samples.bars(slot)
      local moved = false
      for k = first, last, direction do
        local bars = EDITOR.bars[k]
        local beyond = current == nil or (direction > 0 and bars > current + 1e-9) or (direction < 0 and bars < current - 1e-9)
        if beyond then
          S.lib.samples.set_bars(slot, bars)
          if S.lib.samples.bars(slot) ~= current then
            moved = true
            break
          end
        end
      end
      if not moved then return end
    end
  end

  local TURNS = {
    mode = function(slot, record, d)
      local mode = util.clamp(record.mode + d, 1, #S.lib.samples.SAMPLES.modes)
      if mode ~= record.mode then remake(slot, record, "mode", mode) end
    end,
    -- in off the count is kept for when equal is picked, and nothing is made
    amount = function(slot, record, d)
      local low, high = M.amount_range(record)
      local name = mode_name(record)
      local field = name == "transients" and "sensitivity" or "count"
      local value = util.clamp(record[field] + d, low, high)
      if value == record[field] then return end
      if name == "off" then S.lib.samples.set(slot, field, value) else remake(slot, record, field, value) end
    end,
    tempo = turn_tempo,
    bars = function(slot, _, d) turn_bars(slot, d) end,
    key = function(slot, record, d)
      local key = util.clamp((record.key or -1) + d, -1, 127)
      if key < 0 then key = nil end
      if key ~= record.key then S.lib.samples.set(slot, "key", key) end
    end,
    norm = function(slot, record, d)
      local normalize = d > 0
      if normalize ~= (record.normalize == true) then S.lib.samples.set(slot, "normalize", normalize) end
    end,
  }

  -- Turn the row named `name` by d
  function M.turn_row(name, d)
    if not editor.open or d == 0 or not TURNS[name] then return end
    local record = settings(editor.slot)
    if not record then return end
    TURNS[name](editor.slot, record, d)
    request_redraw()
  end

  ---------------------------------------------------------------------------
  -- Drawing and hints
  ---------------------------------------------------------------------------

  local function bars_text(bars)
    if bars == nil then return EDITOR.none_text end
    for value, text in pairs(EDITOR.bar_texts) do
      if math.abs(bars - value) < 1e-9 then return text end
    end
    if math.abs(bars - round(bars)) < 1e-9 then return string.format("%d", round(bars)) end
    return string.format("%.2f", bars)
  end

  local function seconds_text(seconds)
    if seconds < EDITOR.layout.seconds_coarse_from then return string.format("%.3fs", seconds) end
    return string.format("%.2fs", seconds)
  end

  -- Each field's label and value (an empty value draws the label alone)
  local FIELD_TEXTS = {
    mode = function(_, record) return "mode", mode_name(record) end,
    amount = function(_, record)
      if mode_name(record) == "transients" then return "sens", string.format("%d%%", record.sensitivity) end
      return "count", tostring(record.count)
    end,
    slice = function(slot)
      if S.lib.slices.analyzing(slot) then return "analyzing", "" end
      local list = markers(slot)
      return "slice", selected(list) .. "/" .. #list
    end,
    at = function(slot)
      local list = markers(slot)
      return "at", seconds_text(list[selected(list)] / rate(slot))
    end,
    tempo = function(_, record)
      return "tempo", record.tempo and string.format("%.1f", record.tempo) or EDITOR.none_text
    end,
    bars = function(slot) return "bars", bars_text(S.lib.samples.bars(slot)) end,
    key = function(_, record)
      return "key", record.key and musicutil.note_num_to_name(record.key, true) or EDITOR.none_text
    end,
    norm = function(slot, record)
      if not record.normalize then return "norm", "off" end
      local gain = math.max(S.lib.samples.gain(slot), 1e-9)
      return "norm", string.format("%+.1fdB", 20 * math.log(gain) / math.log(10))
    end,
  }

  -- The x a fraction of the slot is at across the screen
  local function x_of(fraction)
    local width = EDITOR.layout.screen_width
    return util.clamp(math.floor(fraction * width), 0, width - 1)
  end

  -- The 64 points, point_width px each from x 0, at one level; a slot with
  -- no peaks is a flat line
  local function draw_wave(slot)
    local L, LEVELS = EDITOR.layout, EDITOR.levels
    local peaks = S.lib.waveforms.bins(slot, S.constants.WAVEFORM_POINTS)
    if not peaks then
      screen.level(LEVELS.wave_empty)
      screen.move(0, L.wave_center)
      screen.line(L.screen_width - 1, L.wave_center)
      screen.stroke()
      return
    end
    screen.level(LEVELS.wave)
    for point = 1, #peaks do
      local half = math.floor(util.clamp(peaks[point], 0, 1) * L.wave_half + 0.5)
      screen.rect((point - 1) * L.point_width, L.wave_center - half, L.point_width, 2 * half + 1)
    end
    screen.fill()
  end

  -- The spans of the slices the voices reading the slot play (on span_y),
  -- then a tick per marker over them, the selected one brightest
  local function draw_marks(slot)
    local total = frames(slot)
    if not total or total <= 0 then return end
    local L, LEVELS = EDITOR.layout, EDITOR.levels
    local list = markers(slot)
    screen.level(LEVELS.span)
    for voice = 1, NUM_VOICES do
      if voice_buffer_slot(voice) == slot then
        for _, n in ipairs(S.lib.slices.playing(voice) or {}) do
          if list[n] then
            screen.move(x_of(list[n] / total), L.span_y)
            screen.line(math.max(x_of((list[n + 1] or total) / total) - 1, x_of(list[n] / total)), L.span_y)
            screen.stroke()
          end
        end
      end
    end
    local chosen = selected(list)
    for index, marker in ipairs(list) do
      screen.level(index == chosen and LEVELS.selected_tick or LEVELS.tick)
      screen.rect(x_of(marker / total), L.tick_y, 1, L.tick_height)
      screen.fill()
    end
  end

  -- The selected voice's playhead while it runs on the slot's audio
  local function draw_head(slot)
    local voice = S.selected_voice
    if voice_buffer_slot(voice) ~= slot or not S.lib.playheads.has_audio(slot) then return end
    local position = S.lib.playheads.position(voice)
    if not position then return end
    local L = EDITOR.layout
    screen.level(EDITOR.levels.head)
    screen.move(x_of(position), L.wave_top)
    screen.line(x_of(position), L.wave_bottom)
    screen.stroke()
  end

  -- The levels of a field's label and value: the picked field (rows view)
  -- or the slice line (markers view) bright, the rest dim, each label
  -- dimmer than its value so the two fields of a line read apart
  local function field_levels(name)
    local LEVELS = EDITOR.levels
    local picked = (editor.view == "rows" and EDITOR.rows[editor.row] == name)
      or (editor.view == "markers" and LINE_OF[name] == MARKERS_LINE)
    if picked then return LEVELS.picked_label, LEVELS.picked end
    return LEVELS.label, LEVELS.value
  end

  local function draw_line(line, y)
    local L = EDITOR.layout
    local slot = editor.slot
    local record = settings(slot)
    local places = {{L.left_x, L.left_right}, {L.right_x, L.value_right}}
    for index, name in ipairs(line.fields) do
      local label, value = FIELD_TEXTS[name](slot, record)
      local label_level, value_level = field_levels(name)
      screen.level(label_level)
      screen.move(places[index][1], y)
      screen.text(label)
      if value ~= "" then
        screen.level(value_level)
        screen.move(places[index][2], y)
        screen.text_right(value)
      end
    end
  end

  local function cursor_line()
    if editor.view == "rows" then return LINE_OF[EDITOR.rows[editor.row]] end
    return MARKERS_LINE
  end

  local function draw()
    if not editor.open or not settings(editor.slot) then return end
    local L, LEVELS = EDITOR.layout, EDITOR.levels
    screen.level(LEVELS.title)
    screen.move(0, L.title_y)
    screen.text("buf " .. editor.slot)
    screen.level(LEVELS.title_right)
    screen.move(L.title_right, L.title_y)
    screen.text_right("slices")
    draw_wave(editor.slot)
    draw_marks(editor.slot)
    draw_head(editor.slot)
    field_list.draw(LINES, cursor_line(), {visible = L.visible, first_y = L.first_y, spacing = L.spacing,
      value_right = L.value_right}, draw_line)
  end

  -- The "hints" flash while one shows (the editor's flashes are BUFFER's)
  local function hints(alt_held)
    local shown = S.lib.ui_flash.text("hints")
    if shown then return shown end
    if editor.view == "rows" then return alt_held and "E2 rows E3 edit" or "E2 slices E3 edit K2 back" end
    return alt_held and "E2 rows E3 fine K3 delete" or "E2 slice E3 nudge K3 add"
  end

  ---------------------------------------------------------------------------
  -- Encoders, keys, the frame clock and the arc's readings
  ---------------------------------------------------------------------------

  -- ALT+E2 goes to the rows (from the markers, on the row last picked) and
  -- picks a row; E2 picks a marker, or from the rows goes back to the
  -- markers; E3 nudges (ALT: finely) or edits the picked row
  local function enc(n, d)
    if not editor.open then return end
    if n == 2 then
      if S.alt_held then
        if editor.view == "rows" then
          editor.row = util.clamp(editor.row + d, 1, #EDITOR.rows)
        else
          editor.view = "rows"
        end
      elseif editor.view == "rows" then
        editor.view = "markers"
      else
        M.pick_marker(d)
      end
    elseif n == 3 then
      if editor.view == "rows" then M.turn_row(EDITOR.rows[editor.row], d) else M.nudge(d, S.alt_held) end
    end
    request_redraw()
  end

  -- At the press: K2 closes (with ALT nothing); in the markers view K3 adds
  -- a marker, ALT+K3 deletes the selected one
  local function key(n, z)
    if not editor.open or z ~= 1 then return end
    if n == 2 then
      if not S.alt_held then M.close() end
    elseif n == 3 and editor.view == "markers" then
      if S.alt_held then M.delete() else M.add() end
    end
  end

  -- The frame clock draws every frame while something on the slot moves or
  -- an analysis runs (its report changes the slice line)
  local function animates()
    if not editor.open then return false end
    return S.lib.playheads.moving(editor.slot) or (M.ready() and S.lib.slices.analyzing(editor.slot) == true)
  end

  -- Where the four arc rings stand (lib/arc/buffer.lua): the selected
  -- marker among the markers, its place in the slot, the amount in its
  -- range and the tempo in its (nil: no tempo)
  function M.ring_fractions()
    local record = editor.open and settings(editor.slot)
    if not record then return nil end
    local list = markers(editor.slot)
    local index = selected(list)
    local total = frames(editor.slot)
    local low, high = M.amount_range(record)
    local amount = mode_name(record) == "transients" and record.sensitivity or record.count
    local SAMPLES = S.lib.samples.SAMPLES
    return {
      marker = #list > 1 and (index - 1) / (#list - 1) or 0,
      position = total and total > 0 and list[index] / total or 0,
      amount = (amount - low) / (high - low),
      tempo = record.tempo and (record.tempo - SAMPLES.tempo_min) / (SAMPLES.tempo_max - SAMPLES.tempo_min) or nil,
    }
  end

  -- The tempo row's range and step, for arc ring 4
  function M.tempo_range()
    local SAMPLES = S.lib.samples.SAMPLES
    return SAMPLES.tempo_min, SAMPLES.tempo_max, EDITOR.tempo_step
  end

  owner = {draw = draw, hints = hints, enc = enc, key = key, animates = animates}
  M.owner = owner

  -- While the key row is picked, a MIDI note's start sets the key to its
  -- number (its key modulo 128); the hook only notes it, and the next clock
  -- step sets it (a hook sends nothing)
  S.register_note_hook({name = "slice editor", started = function(_, _, note)
    if not editor.open or editor.view ~= "rows" or EDITOR.rows[editor.row] ~= "key" then return end
    if note.owner ~= S.lib.midi_in.MIDI.owner or type(note.key) ~= "number" then return end
    pending_key = math.floor(note.key) % 128
  end})
  S.lib.lfos.on_step(function()
    if pending_key == nil then return end
    local note = pending_key
    pending_key = nil
    if editor.open and settings(editor.slot) then
      S.lib.samples.set(editor.slot, "key", note)
      request_redraw()
    end
  end)

  ---------------------------------------------------------------------------
  -- BUFFER's slices field and waveform marks
  ---------------------------------------------------------------------------

  -- "off", "eq 12" or "tran 12" (the slot's count), "--" for no audio
  function M.slot_text(slot)
    local record = settings(slot)
    if not record then return EDITOR.none_text end
    local short = EDITOR.short_modes[mode_name(record)]
    if not short or short == EDITOR.short_modes.off then return EDITOR.short_modes.off end
    return short .. " " .. S.lib.slices.count(slot)
  end

  -- The slot's slice starts as fractions of its valid region, ascending, or
  -- nil when it has fewer than two
  function M.starts(slot)
    local total = frames(slot)
    if not total or total <= 0 or not settings(slot) then return nil end
    local list = markers(slot)
    if #list < 2 then return nil end
    local fractions = {}
    for index, marker in ipairs(list) do fractions[index] = marker / total end
    return fractions
  end

  return M
end

-- lib/pages/buffer.lua
-- The BUFFER page (3.3): eleven fields on the left (the selected voice's
-- source and the record settings, a bookmark, a long file's start, the
-- scrub friction), four at a time, over an input meter; on the right the
-- cursor slot's waveform with its voices' playheads, the record head and
-- the selected voice's bookmarks, over three of the eight slot rows
-- (S.BUFFER_PAGE for the layout and the file selector, S.buffer_page for
-- the cursors). E2 picks a slot, ALT+E2 a field, E3 edits the field; K3
-- records into the cursor slot (or stops); K2 and ALT+K2/ALT+K3 act on
-- release, by how long they were held (hold_seconds): K2 opens the file
-- selector or loads a random file, ALT+K2 clears or fills the empty slots,
-- ALT+K3 saves the slot or its loop region. The input meter's polls run
-- only while the page shows. Registers its S.registry.pages record and a
-- cleanup step; INPUT_METER, input_meter_segments and the meter state are
-- fields of this module's table (S.lib.pages_buffer). The functions that
-- were global stay global.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local NUM_VOICES = S.constants.NUM_VOICES
  local UI_PAGES = S.constants.UI_PAGES
  local fileselect = require "fileselect"

  -- BUFFER page layout. Left column (x 0 to divider_x - 2): field_visible
  -- field rows from field_first_y, field_spacing apart (the cursor ">" at
  -- cursor_x, the label at label_x, cut to end label_gap px before the
  -- value, which is right-aligned at field_value_right), their scroll marker
  -- on the divider; then the input meter on meter_y: "in" at label_x and
  -- eight segment_width x segment_height segments from meter_x. Right
  -- column: the cursor slot's waveform, wave_columns columns from wave_x
  -- (one per peak), wave_top to wave_bottom around wave_center_y, a column
  -- wave_half_height px each way at a peak of 1; the heads over it (a voice's
  -- spread on spread_y, the record head dotted); the bookmark ticks
  -- (bookmark_height px from bookmark_y); then visible_rows slot rows from
  -- row_first_y, row_spacing apart (field_list's scroll marker at x 127):
  -- the slot number at slot_x, the name from name_x, the seconds or the
  -- recording's state right-aligned at value_right; the cursor row also
  -- lists the voices reading the slot, right-aligned before its seconds, at
  -- most voices_max_width wide and never into the name's first
  -- name_min_width px (the voices shorten to "v2+" first). Strings in a row
  -- stay column_gap px apart. levels: the waveform, heads and ticks.
  -- hold_seconds: K2, ALT+K2 and ALT+K3 released this long after their
  -- press act as holds.
  S.BUFFER_PAGE = {
    field_first_y = 16,
    field_spacing = 8,
    field_visible = 4,
    cursor_x = 0,
    label_x = 5,
    label_gap = 0,          -- the layout estimate is wider than the font, so the font leaves a gap
    field_value_right = 54,
    meter_y = 49,
    meter_x = 17,
    segment_width = 3,
    segment_gap = 1,
    segment_height = 5,
    meter_off_level = 1,
    meter_on_level = 10,
    meter_peak_level = 15,
    divider_x = 56,
    divider_top = 10,
    divider_bottom = 52,
    wave_x = 60,
    wave_columns = 64,
    wave_top = 11,
    wave_bottom = 27,
    wave_center_y = 19,
    wave_half_height = 8,
    spread_y = 28,
    bookmark_y = 29,        -- y 29-30: y 31 stays clear above the slot rows' glyphs
    bookmark_height = 2,
    levels = {divider = 1, wave_inside = 8, wave_outside = 3, wave_unread = 6, wave_empty = 1,
      head = 15, other_head = 11, spread = 4, record_head = 12, bookmark = 6, recalled = 15},
    row_first_y = 37,
    row_spacing = 7,        -- three rows at y 37-51, clear of the hint row at y 62
    visible_rows = 3,
    slot_x = 59,
    name_x = 65,
    value_right = 124,      -- clear of the scroll marker at x 127
    column_gap = 3,
    voices_max_width = 25,  -- "v2 v6" under the layout test's width estimate
    name_min_width = 12,    -- the cursor row's name keeps this much (a row with 16.0s still fits "v2+")
    minute_from = 59.95,    -- slot lengths from here on (60.0 to a tenth) show as m:ss ("1:05")
    checking_text = "...",  -- the length of a slot whose long file the engine is still checking
    hold_seconds = 0.5,
    -- the start field: below `below` s it shows the start rounded to `step`
    -- s, as `format` of start / `unit`, so the label "start" always fits
    -- whole beside it; ALT+E3 moves one step, E3 at least start_min_step
    start_bands = {
      {below = 10, step = 0.01, unit = 1, format = "%.2fs"},
      {below = 100, step = 0.1, unit = 1, format = "%.1fs"},
      {below = 1000, step = 1, unit = 1, format = "%ds"},
      {below = 6000, step = 1, unit = 1, format = "m:ss"},
      {below = 60000, step = 60, unit = 60, format = "%dm"},
      {below = math.huge, step = 3600, unit = 3600, format = "%dh"},
    },
    start_min_step = 0.1,
    cache_limit = 256,      -- measured widths and cut texts kept, at most, before they are forgotten
    file_selector_open = false,     -- K2's file selector owns the screen: redraw() draws it
    file_selector_callback = nil,   -- the callback K2 gave fileselect.enter
    script_key = nil,               -- Strata's key and enc as K2 opened the selector
    script_enc = nil
  }
  local PAGE = S.BUFFER_PAGE
  local LEVELS = PAGE.levels

  -- The cursors: slot (1..NUM_BUFFERS, what E2 picks and the keys act on)
  -- and field (1..#BUFFER_FIELDS, what ALT+E2 picks and E3 edits)
  S.buffer_page = {slot = 1, field = 1}

  -- Show `text` (a save result, a failed load, a random file) in BUFFER's
  -- hint row for HEADER.flash_seconds (1.5 s), through the shared "hints"
  -- flash (lib/ui/flash.lua), owned by BUFFER: redraw() draws it there
  -- instead of the key hints while BUFFER is up (other pages keep their own
  -- hints; draw_hints cuts it to the screen), and its clock asks for a
  -- redraw when it ends
  function buffer_page_flash(text)
    S.lib.ui_flash.start("hints", text, S.constants.HEADER.flash_seconds, UI_PAGES.index.BUFFER)
  end

  -- Measured text widths, kept per string: the values, seconds and voices
  -- texts repeat from frame to frame, so a steady redraw measures nothing.
  -- Bounded: past cache_limit entries they are all forgotten (a turn
  -- through a long file's start makes a new text at every detent)
  local measured = {widths = {}, count = 0, cuts = {}, cut_count = 0}
  local function text_width(text)
    local width = measured.widths[text]
    if not width then
      if measured.count >= PAGE.cache_limit then measured.widths, measured.count = {}, 0 end
      width = screen.text_extents(text)
      measured.widths[text] = width
      measured.count = measured.count + 1
    end
    return width
  end

  -- Texts cut to a width, per text and width (cut once, a character at a
  -- time): the field labels beside a wide value. Bounded as the widths
  local function cut_text(text, max_width)
    local cuts = measured.cuts[text]
    local cut = cuts and cuts[max_width]
    if not cut then
      if measured.cut_count >= PAGE.cache_limit then measured.cuts, measured.cut_count = {}, 0 end
      cut = S.lib.ui_text.fit_text(text, max_width)
      measured.cuts[text] = measured.cuts[text] or {}
      measured.cuts[text][max_width] = cut
      measured.cut_count = measured.cut_count + 1
    end
    return cut
  end

  local function cursor_slot()
    S.buffer_page.slot = util.clamp(math.floor(tonumber(S.buffer_page.slot) or 1), 1, NUM_BUFFERS)
    return S.buffer_page.slot
  end

  ---------------------------------------------------------------------------
  -- The fields: name (layout states), label, value(), and either param_id()
  -- (E3 is enc_param_delta) or enc(d); active() false dims the row
  ---------------------------------------------------------------------------

  local function voice_param(key) return "v" .. S.selected_voice .. "_" .. key end

  local function option_text(id)
    local param = params:lookup_param(id)
    return param.options[params:get(id)] or ""
  end

  -- 5% (a fine step shows its tenth: 99.5%)
  local function percent_text(value)
    local whole = math.floor(value + 0.5)
    if math.abs(value - whole) < 1e-6 then return string.format("%d%%", whole) end
    return string.format("%.1f%%", value)
  end

  local RECORD_SOURCE_TEXTS = {input = "in", ["pre-master"] = "pre", ["post-master"] = "post"}
  local function record_source_text()
    local name = option_text("record_source")
    return RECORD_SOURCE_TEXTS[name] or (name:match("^voice (%d+)$") and "v" .. name:match("^voice (%d+)$")) or name
  end

  local function synced() return params:get("record_sync") > 1 end

  -- "16b", or the whole beats a slot holds at this tempo with " max" when
  -- the record beats need longer than a slot ("<1b max" when not one beat
  -- fits: the take is then a slot long, under a beat). The beats are the
  -- take's own (S.lib.record.take_length), so the field names what K3
  -- records (#321)
  local function beats_text()
    local length = S.lib.record.take_length()
    if length.beats == 0 then return "<1b max" end
    return length.beats .. "b" .. (length.capped and " max" or "")
  end

  -- The bookmark the bm field shows: the selected voice's last recalled, or
  -- nil ("-") while it has recalled none
  local function shown_bookmark()
    return S.lib.positions.last_recalled(S.selected_voice)
  end

  -- E3 on bm: step 1..NUM_BOOKMARKS and recall the bookmark it lands on,
  -- only when that changes what the field shows (so a turn against 1 or 4
  -- never restarts the scan); from none, the first detent either way lands
  -- on 1. ALT+E3 recalls the bookmark shown again (1 from none), so the
  -- playhead goes back to it with no jump to a neighbor first (#431). Under
  -- quantize_actions the recall waits for the beat or bar (3.4, key
  -- bookmark<v>), and the next detent steps from the bookmark that waits
  local bookmark_enc
  do
    local waiting = {}  -- per voice, the bookmark its waiting recall lands on
    local function recall(voice_idx, n)
      waiting[voice_idx] = n
      S.lib.quantize.schedule("bookmark" .. voice_idx, function() S.lib.positions.recall_bookmark(voice_idx, n) end, "v" .. voice_idx .. " bm " .. n)
    end

    function bookmark_enc(d)
      local voice_idx = S.selected_voice
      local shown = shown_bookmark()
      if S.lib.quantize.waiting("bookmark" .. voice_idx) then shown = waiting[voice_idx] or shown end
      if S.alt_held then
        recall(voice_idx, shown or 1)
        return
      end
      local n = util.clamp((shown or 0) + d, 1, S.constants.NUM_BOOKMARKS)
      if n ~= shown then recall(voice_idx, n) end
    end
  end

  -- The cursor slot holds a file longer than the seconds a slot holds of it
  -- (its start can move; fewer seconds above 48 kHz, #326)
  local function long_file(slot)
    local buffer = S.buffers[slot]
    return buffer.path ~= nil and buffer.file_seconds ~= nil
      and S.lib.buffers.longest_start(buffer.file_seconds, buffer.sample_rate) > 0
  end

  -- The band a start shows in (start_bands), and the start rounded to its
  -- step: the first band whose rounding stays below its end (9.996 is 10.0)
  local function start_band(start)
    for _, band in ipairs(PAGE.start_bands) do
      local rounded = math.floor(start / band.step + 0.5) * band.step
      if rounded < band.below then return band, rounded end
    end
  end

  -- "9.05s", "12.1s", "1234s" is "20:34", "123m", "17h"; "-" for a file that fits
  local function start_text()
    local slot = cursor_slot()
    if not long_file(slot) then return "-" end
    local band, rounded = start_band(S.buffers[slot].start or 0)
    local whole = math.floor(rounded + 0.5)
    if band.format == "m:ss" then return string.format("%d:%02d", math.floor(whole / 60), whole % 60) end
    if band.unit > 1 then return string.format(band.format, math.floor(rounded / band.unit + 0.5)) end
    if band.step >= 1 then return string.format(band.format, whole) end
    return string.format(band.format, rounded)
  end

  -- E3 on start: one step of the band it shows (at least start_min_step),
  -- ALT+E3 one step, so every detent changes what is shown; the result
  -- rounded to its own band's step, through set_start (which clamps it and
  -- reloads the file once E3 rests)
  local function start_enc(d)
    local slot = cursor_slot()
    if not long_file(slot) then return end
    local start = S.buffers[slot].start or 0
    local band = start_band(start)
    local step = S.alt_held and band.step or math.max(PAGE.start_min_step, band.step)
    local _, rounded = start_band(math.max(0, start + d * step))
    S.lib.buffers.set_start(slot, rounded)
  end

  local BUFFER_FIELDS = {
    {name = "source", label = function() return "v" .. S.selected_voice end,
      param_id = function() return voice_param("source") end,
      value = function() return voice_source_label(S.selected_voice) end},
    {name = "rec", label = "rec", param_id = function() return "record_source" end, value = record_source_text},
    {name = "dur", label = function() return synced() and "len" or "dur" end,
      param_id = function() return synced() and "record_beats" or "record_duration" end,
      value = function()
        if synced() then return beats_text() end
        return string.format("%.1fs", params:get("record_duration"))
      end},
    {name = "lvl", label = "lvl", param_id = function() return "record_level" end,
      value = function() return string.format("%.2f", params:get("record_level")) end},
    {name = "fb", label = "fb", param_id = function() return "record_feedback" end,
      value = function() return percent_text(params:get("record_feedback")) end},
    {name = "loop", label = "loop", param_id = function() return "record_loop" end,
      value = function() return option_text("record_loop") end},
    {name = "thr", label = "thr", param_id = function() return "record_threshold" end,
      value = function() return (option_text("record_threshold"):gsub(" ", "")) end},
    {name = "sync", label = "sync", param_id = function() return "record_sync" end,
      value = function() return option_text("record_sync") end},
    {name = "bm", label = "bm", enc = bookmark_enc,
      active = function() return voice_uses_buffer(S.selected_voice) end,
      value = function()
        local n = shown_bookmark()
        if not n then return "-" end
        return string.format("%d %.2f", n, S.lib.positions.bookmark(S.selected_voice, n) or 0)
      end},
    {name = "start", label = "start", enc = start_enc, value = start_text},
    {name = "fric", label = "fric", param_id = function() return "scrub_friction" end,
      value = function() return percent_text(params:get("scrub_friction")) end},
  }

  local function cursor_field()
    S.buffer_page.field = S.lib.ui_field_list.clamp(BUFFER_FIELDS, S.buffer_page.field)
    return BUFFER_FIELDS[S.buffer_page.field]
  end

  -- One field row at y: the value right-aligned, the label cut to end
  -- label_gap px before it, ">" on the cursor's row. The cursor's row at 15,
  -- the others 4; a row that does nothing for the selected voice (bm on a
  -- voice that reads no buffer) 4 under the cursor, 2 elsewhere
  local function draw_field_row(field, y, selected)
    local level = selected and 15 or 4
    if field.active and not field.active() then level = selected and 4 or 2 end
    local value = field.value()
    local label = type(field.label) == "function" and field.label() or field.label
    screen.level(level)
    if selected then
      screen.move(PAGE.cursor_x, y)
      screen.text(">")
    end
    screen.move(PAGE.field_value_right, y)
    screen.text_right(value)
    local room = PAGE.field_value_right - text_width(value) - PAGE.label_gap - PAGE.label_x
    label = cut_text(label, room)
    if label ~= "" then
      screen.move(PAGE.label_x, y)
      screen.text(label)
    end
  end

  -- The field rows in view (one above the cursor kept), then their scroll
  -- marker on the divider (field_list's geometry, drawn at divider_x)
  local function draw_fields()
    local cursor = cursor_field() and S.buffer_page.field
    local list = S.lib.ui_field_list
    local first = list.first_visible(BUFFER_FIELDS, cursor, PAGE.field_visible)
    for offset = 0, math.min(PAGE.field_visible, #BUFFER_FIELDS - first + 1) - 1 do
      local index = first + offset
      draw_field_row(BUFFER_FIELDS[index], PAGE.field_first_y + offset * PAGE.field_spacing, index == cursor)
    end
    list.draw_marker(first, PAGE.field_visible, #BUFFER_FIELDS, PAGE.field_first_y - 6,
      PAGE.field_first_y + (PAGE.field_visible - 1) * PAGE.field_spacing + 1, PAGE.divider_x)
  end

  ---------------------------------------------------------------------------
  -- The slot rows
  ---------------------------------------------------------------------------

  -- A slot's name for the screen, cut to max_width: the file name without
  -- its extension, as norns' font draws it (S.lib.ui_text.printable: "café"
  -- is "cafe", measured as it is drawn, #551; the slot keeps its real name).
  -- Cached per slot and width until the name changes (load, take, clear),
  -- so a redraw does not measure names a character at a time
  local display_names = {}
  local function buffer_display_name(slot, max_width)
    local buffer = S.buffers[slot]
    local cache = display_names[slot]
    if not cache or cache.of ~= buffer.name then
      cache = {of = buffer.name, cut = {}}
      display_names[slot] = cache
    end
    if not cache.cut[max_width] then
      local name = buffer.name:gsub("%.[^.]*$", "")
      if name == "" then name = buffer.name end
      cache.cut[max_width] = S.lib.ui_text.fit_text(S.lib.ui_text.printable(name), max_width)
    end
    return cache.cut[max_width]
  end

  -- A slot with no name (nothing loaded or recorded) shows "-"; a free one
  -- (S.lib.buffers.is_free: empty, or a remembered file missing on start)
  -- shows no seconds either. What the slot holds says so, never its name (a
  -- file may be called "empty", #436): a file or a settled take has a path,
  -- and a dub into an empty slot is a named take once it holds audio
  -- (loaded, before its path comes at "ended", #400)
  local function slot_has_name(buffer)
    return buffer.path ~= nil or buffer.loaded
  end

  local function slot_is_empty(slot)
    return S.lib.buffers.is_free(slot)
  end

  -- The voices reading a slot ("v2 v6"), cut to max_width a whole voice at
  -- a time, with "+" for the voices left out
  local function slot_voices_text(slot, max_width)
    local readers = {}
    for voice = 1, NUM_VOICES do
      if voice_buffer_slot(voice) == slot then table.insert(readers, "v" .. voice) end
    end
    local text = table.concat(readers, " ")
    local shown = #readers
    while shown > 0 and text_width(text) > max_width do
      shown = shown - 1
      text = table.concat(readers, " ", 1, shown) .. "+"
    end
    if shown == 0 then return "" end
    return text
  end

  -- A slot's length: seconds to a tenth ("16.5s") below a minute, minutes
  -- and whole seconds ("1:05") from 60 s on (a length that rounds to 60.0
  -- is a minute, never "60.0s")
  local function slot_seconds_text(seconds)
    if seconds < PAGE.minute_from then return string.format("%.1fs", seconds) end
    local whole = math.floor(seconds + 0.5)
    return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
  end
  M.slot_seconds_text = slot_seconds_text

  -- What a recording slot shows for its length: ARM while it waits to
  -- start, REC for a replace take, DUB for a playable one-shot, LOOP for a
  -- loop recording; nil when it does not record
  local function slot_record_text(slot)
    if not S.buffers[slot].recording then return nil end
    local state = S.lib.record.state(slot)
    if state and state.phase == "armed" then return "ARM" end
    if state and state.kind == "playable" then return state.loop and "LOOP" or "DUB" end
    return "REC"
  end

  -- The widest length a slot of this tier shows: its buffer length, or below
  -- a minute ("59.9s", wider than "5:00") when the tier's slots reach one
  local function widest_seconds_width()
    local longest = S.performance.buffer_seconds
    local width = text_width(slot_seconds_text(longest))
    if longest >= PAGE.minute_from then width = math.max(width, text_width(slot_seconds_text(59.9))) end
    return width
  end

  -- One slot row at y: slot number, name and seconds (or the recording's
  -- state); the cursor row is bright and also lists the voices reading it
  local function draw_slot_row(row, y, selected, value_right)
    local slot = row.slot
    local buffer = S.buffers[slot]
    local empty = slot_is_empty(slot)
    local level = 2
    if selected then
      level = 15
    elseif buffer.loaded or buffer.recording then
      level = 6
    end
    screen.level(level)
    screen.move(PAGE.slot_x, y)
    screen.text(tostring(slot))
    -- names end before the seconds column (the widest seconds: "16.0s" on
    -- standard, "59.9s" once the tier's slots reach a minute)
    local name_right = value_right - widest_seconds_width() - PAGE.column_gap
    if not empty then
      -- "..." while the engine checks a long file (the old length is still reported)
      local seconds = slot_record_text(slot)
        or (buffer.checking_from ~= nil and PAGE.checking_text or slot_seconds_text(buffer.seconds))
      screen.move(value_right, y)
      screen.text_right(seconds)
      if selected then name_right = value_right - text_width(seconds) - PAGE.column_gap end
    end
    if selected then
      local voices_room = name_right - PAGE.name_x - PAGE.name_min_width - PAGE.column_gap
      local voices = slot_voices_text(slot, math.min(PAGE.voices_max_width, voices_room))
      if voices ~= "" then
        screen.move(name_right, y)
        screen.text_right(voices)
        name_right = name_right - text_width(voices) - PAGE.column_gap
      end
    end
    local name = slot_has_name(buffer) and buffer_display_name(slot, math.max(name_right - PAGE.name_x, 0)) or "-"
    if name ~= "" then
      screen.move(PAGE.name_x, y)
      screen.text(name)
    end
  end

  ---------------------------------------------------------------------------
  -- The waveform, its heads and the bookmarks (the cursor slot's)
  ---------------------------------------------------------------------------

  -- The column (x) a fraction of the slot is in
  local function wave_x_of(fraction)
    return PAGE.wave_x + S.lib.playheads.cell_of(fraction, PAGE.wave_columns) - 1
  end

  -- Column k is a vertical line of half-height round(peak x
  -- wave_half_height): inside the selected voice's loop at wave_inside,
  -- outside it at wave_outside (when that voice reads the slot), else at
  -- wave_unread; a stroke per run of one level. An empty slot, or one with
  -- no valid peaks, is a flat line at wave_empty
  local function draw_waveform(slot)
    local peaks = S.lib.waveforms.bins(slot, PAGE.wave_columns)
    local center = PAGE.wave_center_y
    if not peaks then
      screen.level(LEVELS.wave_empty)
      screen.move(PAGE.wave_x, center)
      screen.line(PAGE.wave_x + PAGE.wave_columns - 1, center)
      screen.stroke()
      return
    end
    local reads = voice_buffer_slot(S.selected_voice) == slot
    local loop_start, loop_end = 0, 1
    if reads then
      loop_start = params:get(voice_param("loop_start"))
      loop_end = loop_start + params:get(voice_param("loop_length"))
    end
    local drawing = nil
    for column = 1, PAGE.wave_columns do
      local level = LEVELS.wave_unread
      if reads then
        local middle = (column - 0.5) / PAGE.wave_columns
        level = (middle >= loop_start and middle < loop_end) and LEVELS.wave_inside or LEVELS.wave_outside
      end
      if level ~= drawing then
        if drawing then screen.stroke() end
        screen.level(level)
        drawing = level
      end
      local half = math.floor(util.clamp(peaks[column], 0, 1) * PAGE.wave_half_height + 0.5)
      local x = PAGE.wave_x + column - 1
      screen.move(x, center - half)
      screen.line(x, center + half)
    end
    screen.stroke()
  end

  -- One running voice's head: a line over the waveform at its playhead,
  -- its spread on spread_y
  local function draw_head(voice_idx, level)
    local position = S.lib.playheads.position(voice_idx)
    if not position then return end
    local spread = S.lib.playheads.spread(voice_idx) or 0
    if spread > 0 then
      screen.level(LEVELS.spread)
      screen.move(wave_x_of(position - spread / 2), PAGE.spread_y)
      screen.line(wave_x_of(position + spread / 2), PAGE.spread_y)
      screen.stroke()
    end
    local x = wave_x_of(position)
    screen.level(level)
    screen.move(x, PAGE.wave_top)
    screen.line(x, PAGE.wave_bottom)
    screen.stroke()
  end

  -- The heads of the voices reading the slot (the selected voice's last,
  -- brightest), the record head dotted while the slot records playably,
  -- and the selected voice's bookmark ticks when it reads the slot. Heads,
  -- spreads and ticks only on a slot that reports audio, as the grid's
  -- position rows (S.lib.playheads.has_audio, #433)
  local function draw_heads(slot)
    local selected = S.selected_voice
    local audio = S.lib.playheads.has_audio(slot)
    if audio then
      for voice_idx = 1, NUM_VOICES do
        if voice_idx ~= selected and voice_buffer_slot(voice_idx) == slot then draw_head(voice_idx, LEVELS.other_head) end
      end
      if voice_buffer_slot(selected) == slot then draw_head(selected, LEVELS.head) end
    end
    local record_head = S.lib.playheads.record_head(slot)
    if record_head then
      local x = wave_x_of(record_head)
      screen.level(LEVELS.record_head)
      for y = PAGE.wave_top, PAGE.wave_bottom, 2 do screen.rect(x, y, 1, 1) end
      screen.fill()
    end
    if not audio or voice_buffer_slot(selected) ~= slot then return end
    local recalled = S.lib.positions.last_recalled(selected)
    for n = 1, S.constants.NUM_BOOKMARKS do
      screen.level(n == recalled and LEVELS.recalled or LEVELS.bookmark)
      screen.rect(wave_x_of(S.lib.positions.bookmark(selected, n) or 0), PAGE.bookmark_y, 1, PAGE.bookmark_height)
      screen.fill()
    end
  end

  ---------------------------------------------------------------------------
  -- The input meter: norns' amp_in_l and amp_in_r polls, running only while
  -- BUFFER shows (enter starts them, leave and cleanup stop them). It shows
  -- the louder channel in segments of db_per_segment dB from floor_db, and
  -- holds the highest segment for peak_hold_seconds
  ---------------------------------------------------------------------------

  M.INPUT_METER = {poll_seconds = 0.05, segments = 8, floor_db = -48, db_per_segment = 6, peak_hold_seconds = 1}
  local INPUT_METER = M.INPUT_METER
  local INPUT_POLLS = {"amp_in_l", "amp_in_r"}

  -- amps: the latest value per poll; peak and peak_at: the held segment and
  -- when it was last reached (util.time()); shown: what the screen last
  -- drew (a poll asks for a redraw only when it changes); polls: the
  -- running poll objects, per name
  M.meter = {amps = {}, peak = 0, peak_at = 0, shown = nil, polls = {}}
  local meter = M.meter

  -- Segments lit for an amplitude (0-1 full scale): 0 at or below floor_db
  -- (and for 0, negative or NaN values), all of them at 0 dB and above
  function M.input_meter_segments(amp)
    if type(amp) ~= "number" or not (amp > 0) then return 0 end
    local db = 20 * math.log(amp) / math.log(10)
    local segments = math.ceil((db - INPUT_METER.floor_db) / INPUT_METER.db_per_segment)
    return math.floor(math.max(0, math.min(INPUT_METER.segments, segments)))
  end

  local function meter_level()
    local louder = 0
    for _, name in ipairs(INPUT_POLLS) do louder = math.max(louder, meter.amps[name] or 0) end
    return M.input_meter_segments(louder)
  end

  -- The held peak segment, or 0 once peak_hold_seconds have passed
  local function held_peak(now)
    if now - meter.peak_at < INPUT_METER.peak_hold_seconds then return meter.peak end
    return 0
  end

  -- A poll's value: the peak follows the level up (and is held from the
  -- moment the level last reached it); a redraw only when the level or the
  -- held peak changed, of the screen alone (no arc ring shows the meter,
  -- #434), and none while the file selector covers the page (#435: the
  -- selector's close asks for the redraw that shows the meter again)
  local function meter_input(name, value)
    if type(value) ~= "number" or value ~= value then value = 0 end
    meter.amps[name] = value
    local level, now = meter_level(), util.time()
    if level >= held_peak(now) then
      meter.peak, meter.peak_at = level, now
    end
    local shown = level * (INPUT_METER.segments + 1) + held_peak(now)
    if shown ~= meter.shown then
      meter.shown = shown
      if not PAGE.file_selector_open then S.lib.ui_frame.request_screen_redraw() end
    end
  end

  local function reset_meter()
    for _, name in ipairs(INPUT_POLLS) do meter.amps[name] = 0 end
    meter.peak, meter.peak_at, meter.shown = 0, 0, nil
  end

  -- The polls are looked up at each start: norns replaces its poll objects
  -- whenever it re-registers the polls (an engine load). A norns without
  -- them leaves the meter dark
  local function start_input_meter()
    reset_meter()
    for _, name in ipairs(INPUT_POLLS) do
      local input_poll = poll.set(name, function(value) meter_input(name, value) end)
      meter.polls[name] = input_poll
      if input_poll then
        input_poll.time = INPUT_METER.poll_seconds
        input_poll:start()
      end
    end
  end

  local function stop_input_meter()
    for _, name in ipairs(INPUT_POLLS) do
      local input_poll = meter.polls[name]
      if input_poll then
        input_poll:stop()
        input_poll.callback = nil  -- a value already on its way after leave asks for no redraw
      end
    end
  end

  local function draw_input_meter()
    local level, peak = meter_level(), held_peak(util.time())
    screen.level(4)
    screen.move(PAGE.label_x, PAGE.meter_y)
    screen.text("in")
    for segment = 1, INPUT_METER.segments do
      local segment_level = PAGE.meter_off_level
      if segment <= level then
        segment_level = PAGE.meter_on_level
      elseif segment == peak then
        segment_level = PAGE.meter_peak_level
      end
      screen.level(segment_level)
      screen.rect(PAGE.meter_x + (segment - 1) * (PAGE.segment_width + PAGE.segment_gap),
        PAGE.meter_y - PAGE.segment_height, PAGE.segment_width, PAGE.segment_height)
      screen.fill()
    end
  end

  ---------------------------------------------------------------------------
  -- Drawing, hints, encoders and keys
  ---------------------------------------------------------------------------

  -- The slot list's rows for field_list (every slot takes a cursor stop)
  local slot_list_rows = {}
  for slot = 1, NUM_BUFFERS do slot_list_rows[slot] = {label = tostring(slot), slot = slot} end

  function redraw_buffer()
    local slot = cursor_slot()
    -- the divider first: the fields' scroll marker is drawn over it
    screen.level(LEVELS.divider)
    screen.move(PAGE.divider_x, PAGE.divider_top)
    screen.line(PAGE.divider_x, PAGE.divider_bottom)
    screen.stroke()
    draw_fields()
    draw_input_meter()
    draw_waveform(slot)
    draw_heads(slot)
    -- the slots, scrolled to keep one row above the cursor
    S.lib.ui_field_list.draw(slot_list_rows, slot, {
      visible = PAGE.visible_rows, first_y = PAGE.row_first_y, spacing = PAGE.row_spacing,
      value_right = PAGE.value_right}, draw_slot_row)
  end

  -- When K2 and K3 last went down (util.time()), plain or with ALT: their
  -- release acts by how long they were held, so no clock is needed
  local pressed_at = {}
  local function held_long(n)
    local at = pressed_at[n]
    pressed_at[n] = nil
    return at ~= nil and util.time() - at >= PAGE.hold_seconds
  end

  -- The hold hint's texts per key, {before hold_seconds, from it}: a key
  -- counts as down while it went down on this page (S.key_press_page, which
  -- a page change, the norns menu and the file selector clear) and the page
  -- noted its press. Plain K3 records at the press and has no hold
  local HOLD_HINTS = {
    plain = {[2] = {"K2 up: load", "K2 up: random"}},
    alt = {[2] = {"K2 up: clear", "K2 up: fill"}, [3] = {"K3 up: save", "K3 up: save loop"}},
  }
  local function held_hint()
    for n = 2, 3 do
      local texts = (S.key_press_alt[n] and HOLD_HINTS.alt or HOLD_HINTS.plain)[n]
      if texts and pressed_at[n] and S.key_press_page[n] == UI_PAGES.index.BUFFER then
        return texts, pressed_at[n]
      end
    end
  end

  -- The hint row's keys (redraw() draws the "hints" flash instead while
  -- one shows): while K2, ALT+K2 or ALT+K3 is down, what its release will
  -- do, changing at hold_seconds (the frame clock redraws: animates); else
  -- "stop" while the cursor slot records or is armed, "..." while its take
  -- that ended waits for the engine (K3 does nothing then)
  local function buffer_hints(alt_held)
    local texts, at = held_hint()
    if texts then return util.time() - at >= PAGE.hold_seconds and texts[2] or texts[1] end
    if alt_held then return "K2:clr/fill K3:sv/trim" end
    local buffer = S.buffers[cursor_slot()]
    local record_hint = buffer.finishing and "..." or (buffer.recording and "stop" or "rec")
    return "K2:ld/rnd K3:" .. record_hint
  end

  -- E2 picks a slot, E3 edits the field under the field cursor
  local function buffer_enc(n, d)
    if n == 2 then
      S.buffer_page.slot = util.clamp(cursor_slot() + d, 1, NUM_BUFFERS)
    elseif n == 3 then
      local field = cursor_field()
      if field.enc then
        field.enc(d)
      else
        enc_param_delta(n, field.param_id(), d)
      end
    end
  end

  -- ALT+E2 moves the field cursor; ALT+E3 goes on to buffer_enc (fine
  -- adjustment, through enc_param_delta or the start field's own step)
  local function buffer_alt_enc(n, d)
    if n ~= 2 then return false end
    S.buffer_page.field = S.lib.ui_field_list.move(BUFFER_FIELDS, S.buffer_page.field, d)
    return true
  end

  -- K3 (press) and the arc's button record into the cursor slot, stop it
  -- early while it records, or cancel it while it is armed
  local function record_cursor_slot()
    record_buffer(cursor_slot())
  end

  local function buffer_key(n)
    if n == 2 then
      pressed_at[2] = util.time()
    elseif n == 3 then
      record_cursor_slot()
    end
  end

  -- Save the cursor slot (or, `loop`, its loop region: save_buffer_loop),
  -- shown in the hint row. The save functions decide: a slot recording or
  -- awaiting its take is busy, one the engine reports empty has nothing to
  -- save. A save sent shows saving until the engine reports how it ended:
  -- buffer_save_result then flashes saved or failed.
  local function save_cursor_slot(loop)
    local slot = cursor_slot()
    local sent, reason
    if loop then sent, reason = save_buffer_loop(slot) else sent, reason = save_buffer(slot) end
    if sent then
      buffer_page_flash("saving buf " .. slot .. (loop and " loop" or ""))
    elseif reason == "busy" then
      buffer_page_flash("buf " .. slot .. " busy")
    elseif reason == "empty" then
      buffer_page_flash("buf " .. slot .. " empty")
    end
  end

  -- ALT+K2 and ALT+K3 act on release (design 3.3 section 8.1, the one
  -- exception to acting through alt_action at the press): the press only
  -- notes its time. An ALT press releases through alt_key_release, never
  -- key_release, so ALT+K2 never opens the file selector, even when K1
  -- comes up first
  local function buffer_alt_key(n)
    pressed_at[n] = util.time()
  end

  -- ALT+K2 released: clear the cursor slot, or held, fill every empty slot;
  -- ALT+K3 released: save the cursor slot, or held, its loop region
  local function buffer_alt_key_release(n)
    local long = held_long(n)
    if n == 2 then
      if long then S.lib.files.fill_empty() else clear_buffer(cursor_slot()) end
    elseif n == 3 then
      save_cursor_slot(long)
    end
  end

  -- K2 released: held, a random file into the cursor slot; else open the
  -- file selector for it
  local function buffer_key_release(n)
    if n ~= 2 then return end
    local slot = cursor_slot()
    if held_long(2) then
      S.lib.files.random_into(slot)
      return
    end
    -- the selector takes every key while open, so keys held now are released
    -- there, never reaching key(): forget them
    forget_held_keys()
    -- From play mode norns puts Strata's redraw back while the selector is
    -- open (fs.enter calls norns.menu.init), so Strata's redraws would draw
    -- over the file list: until the callback, which norns calls on a choice
    -- and on a cancel alike, they draw the selector instead
    local function file_chosen(path)
      -- loaded directly (it also shows the path in buf<n>_file): setting the
      -- param would do nothing when it already holds this path. Its folder
      -- is where the next random file comes from
      if path ~= "cancel" then
        S.lib.files.note_chosen(path)
        load_buffer(slot, path)
      end
      close_buffer_file_selector()
    end
    PAGE.file_selector_open = true
    PAGE.file_selector_callback = file_chosen
    PAGE.script_key, PAGE.script_enc = key, enc
    local entered, enter_error = xpcall(function()
      fileselect.enter(_path.audio, file_chosen)
    end, with_traceback)
    if not entered then
      -- no selector is open, so no callback will come: Strata's page, key and
      -- enc come back. fs.enter fails after norns.menu.init() has routed
      -- play mode's keys and encoders to fs.key/fs.enc (_menu.key and
      -- norns.encoders.callback are copied from the globals only in
      -- set_mode(false)), so restoring the globals is not enough: route them
      -- again, as fs.exit does
      key, enc = PAGE.script_key, PAGE.script_enc
      close_buffer_file_selector()
      if not norns.menu.status() then pcall(norns.menu.init) end
      error(enter_error, 0)
    end
  end

  -- The BUFFER K2 selector is closed (its callback ran) or will never call back
  function close_buffer_file_selector()
    PAGE.file_selector_open = false
    PAGE.file_selector_callback = nil
    PAGE.script_key, PAGE.script_enc = nil, nil
    request_redraw()
  end

  -- norns has one file selector. Opened from play mode (BUFFER K2), fs.enter
  -- puts its own key and enc in the globals and keeps Strata's to restore in
  -- fs.exit. A PARAMS file param (or TAPE) opening a selector from the menu
  -- over it replaces its callback and restore list with the menu's: that
  -- exit gives the menu its handlers back, Strata's callback never comes, and
  -- the globals keep the selector's handlers, which norns hands back to play
  -- mode as the menu closes. So when the menu closes (menu_watch.wrapper,
  -- before norns' set_mode(false) reads the globals) and fs.callback is no
  -- longer Strata's, the selector state is cleared and Strata's key and enc
  -- are put back. Only a real menu-to-play change counts (the menu still
  -- open as set_mode(false) starts; fs.enter's and fs.exit's own
  -- norns.menu.init() run in play mode), and a fileselect without a
  -- `callback` field (other norns internals) releases nothing, so a change
  -- there leaves the selector state set rather than breaking BUFFER K2.
  function release_superseded_file_selector()
    if not PAGE.file_selector_open or not norns.menu.status() then return end
    if fileselect.callback == nil then return end
    if fileselect.callback == PAGE.file_selector_callback then return end
    key, enc = PAGE.script_key, PAGE.script_enc
    close_buffer_file_selector()
  end

  ---------------------------------------------------------------------------
  -- The states the layout tests and the page renders draw (each on a fresh
  -- script with BUFFER shown)
  ---------------------------------------------------------------------------

  local LAYOUT = {
    long_names = {"WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
      "café_crème_très_longue.wav", "no_extension_but_long", "drone", "field_rec.flac"},
  }

  function LAYOUT.load_long_names(context)
    for slot = 1, NUM_BUFFERS do
      load_buffer(slot, "/tmp/" .. LAYOUT.long_names[(slot - 1) % #LAYOUT.long_names + 1])
      context.polls.fire("bufferState", (slot - 1) * 1000 + S.performance.buffer_seconds)
    end
  end

  function LAYOUT.voices_on_slot(slot, count)
    for voice = 1, count do params:set("v" .. voice .. "_source", slot + 1) end
  end

  -- As on a high tier with 300 s slots: the page reads S.performance, and
  -- the duration's range ends at the slot length (the script's own start
  -- read a standard tier). The param gets a copy of its spec with the wider
  -- range, so the spec it was built with never changes
  function LAYOUT.as_300_s_tier()
    S.performance = {tier = "high", buffer_seconds = 300, max_grains = 128, history_seconds = 60, reason = "high: setting"}
    -- the param keeps its position in the range: put its value back
    local duration = params:get("record_duration")
    local param = params:lookup_param("record_duration")
    local spec = param.controlspec:copy()
    spec.maxval = 300
    param.controlspec = spec
    params:set("record_duration", duration)
  end

  -- Every slot reports `seconds` (load_long_names, then the new length)
  function LAYOUT.slots_report(context, seconds)
    LAYOUT.load_long_names(context)
    for slot = 1, NUM_BUFFERS do context.polls.fire("bufferState", (slot - 1) * 1000 + seconds) end
  end

  -- The engine's bufferSaveResult report of the slot's newest save
  -- ((save number * 2 + failed) * NUM_BUFFERS + slot index)
  function LAYOUT.save_result_value(slot, failed)
    return (S.buffers[slot].saves_sent * 2 + (failed and 1 or 0)) * NUM_BUFFERS + slot - 1
  end

  -- Slot 1 loaded with 12 s whose peaks rise and fall, as the engine writes
  -- them (the page's waveform reads them on a later frame tick)
  function LAYOUT.slot_with_peaks(context)
    load_buffer(1, "/tmp/" .. LAYOUT.long_names[7])
    local values = {}
    for index = 1, S.constants.WAVEFORM_POINTS do
      values[index] = string.format("%.3f", 0.5 + 0.45 * math.sin(index / 3) * math.sin(index / 17))
    end
    local folder = S.lib.scenes.scene_data_dir
    util.make_dir(folder)
    local file = io.open(folder .. "buf1.peaks", "w")
    if file then
      file:write("strata-peaks 1\nslot 1\nframes " .. (12 * 48000) .. "\nrate 48000\ngeneration 1\npeaks "
        .. table.concat(values, " ") .. "\n")
      file:close()
    end
    context.polls.fire("bufferState", 12)
    context.clock.run_for(0.2)
  end

  -- A file longer than a slot loaded into slot 1, its start at `start`,
  -- the cursor on the start field
  function LAYOUT.long_file_start(context, seconds, start)
    local path = "/tmp/" .. LAYOUT.long_names[2]
    context.audio.files[path] = {2, 48000 * seconds, 48000}
    load_buffer(1, path)
    context.polls.fire("bufferState", S.performance.buffer_seconds)
    S.lib.buffers.set_start(1, start)
    S.buffer_page.field = 10
  end

  -- Each field on the cursor, at a wide value
  local FIELD_VALUES = {
    source = function() params:set("v1_source", 10) end,
    rec = function() params:set("record_source", 3) end,
    dur = function() params:set("record_duration", S.performance.buffer_seconds) end,
    lvl = function() params:set("record_level", 0.5) end,
    fb = function() params:set("record_feedback", 99.5) end,
    loop = function() params:set("record_loop", 2) end,
    thr = function() params:set("record_threshold", 2) end,
    sync = function() params:set("record_sync", 2) end,
    bm = function() params:set("v1_source", 2); S.lib.positions.recall_bookmark(1, 4) end,
    start = function() end,
    fric = function() params:set("scrub_friction", 99.5) end,
  }

  local BUFFER_INDEX = UI_PAGES.index.BUFFER
  local layout_states = {
    {name = "slot 1", setup = function(context) LAYOUT.load_long_names(context); LAYOUT.voices_on_slot(1, 2) end},
    {name = "slot 8", setup = function(context)
      LAYOUT.load_long_names(context); LAYOUT.voices_on_slot(8, 2); S.buffer_page.slot = NUM_BUFFERS end},
    {name = "long names", setup = function(context)
      LAYOUT.load_long_names(context); LAYOUT.voices_on_slot(4, NUM_VOICES); S.buffer_page.slot = 4 end},
    {name = "every slot recording", setup = function()
      for slot = 1, NUM_BUFFERS do record_buffer(slot) end
      LAYOUT.voices_on_slot(1, 1)
    end},
    {name = "saving flash", setup = function(context) LAYOUT.load_long_names(context); save_cursor_slot(false) end},
    {name = "saving loop flash", setup = function(context) LAYOUT.load_long_names(context); save_cursor_slot(true) end},
    {name = "saved flash", setup = function(context)
      LAYOUT.load_long_names(context); S.buffer_page.slot = NUM_BUFFERS; save_cursor_slot(false)
      context.polls.fire("bufferSaveResult", LAYOUT.save_result_value(NUM_BUFFERS, false))
    end},
    {name = "saved loop flash", setup = function(context)
      LAYOUT.load_long_names(context); S.buffer_page.slot = NUM_BUFFERS; save_cursor_slot(true)
      context.polls.fire("bufferSaveResult", LAYOUT.save_result_value(NUM_BUFFERS, false))
    end},
    {name = "save failed flash", setup = function(context)
      LAYOUT.load_long_names(context); S.buffer_page.slot = NUM_BUFFERS; save_cursor_slot(false)
      context.polls.fire("bufferSaveResult", LAYOUT.save_result_value(NUM_BUFFERS, true))
    end},
    {name = "busy flash", setup = function() record_buffer(1); save_cursor_slot(false) end},
    {name = "empty flash", setup = function() save_cursor_slot(false) end},
    {name = "load failed flash", setup = function() buffer_page_flash("buf 8 load failed") end},
    {name = "random file flash", setup = function() buffer_page_flash("buf 8: " .. LAYOUT.long_names[2]) end},
    {name = "filled flash", setup = function() buffer_page_flash("filled 8 slots") end},
    -- an empty folder whose path below the audio folder is too long: its own name
    {name = "no files flash", setup = function()
      local folder = _path.audio .. "a_long_folder_name/another_one/"
      util.make_dir(folder)
      S.lib.files.note_chosen(folder .. "x.wav")
      S.lib.files.random_into(1)
    end},
    {name = "meter peak", setup = function(context)
      context.polls.fire("amp_in_l", 1); context.polls.fire("amp_in_r", 0.2)
      context.polls.fire("amp_in_l", 0.05)
    end},
    -- every recording state on the cursor slot, read by voice 1
    {name = "armed", setup = function()
      LAYOUT.voices_on_slot(1, 1); params:set("record_threshold", 2); record_buffer(1) end},
    {name = "take recording", setup = function() LAYOUT.voices_on_slot(1, 1); record_buffer(1) end},
    {name = "take finishing", setup = function() LAYOUT.voices_on_slot(1, 1); record_buffer(1); record_buffer(1) end},
    {name = "dub recording", setup = function(context)
      LAYOUT.slot_with_peaks(context); LAYOUT.voices_on_slot(1, 1)
      params:set("record_feedback", 50); record_buffer(1)
    end},
    {name = "loop recording", setup = function(context)
      LAYOUT.slot_with_peaks(context); LAYOUT.voices_on_slot(1, 1)
      params:set("record_loop", 2); record_buffer(1)
    end},
    {name = "len 16b max", setup = function()
      params:set("record_sync", 2); params:set("record_beats", 40); S.buffer_page.field = 3 end},
    -- every voice running on one slot, the selected one's loop a part of it
    {name = "seven heads on one slot", setup = function(context)
      LAYOUT.slot_with_peaks(context); LAYOUT.voices_on_slot(1, NUM_VOICES)
      params:set("v1_loop_start", 0.2); params:set("v1_loop_length", 0.5)
      for voice = 1, NUM_VOICES do
        params:set("v" .. voice .. "_buf_pos", (voice - 1) / NUM_VOICES)
        if not S.voices[voice].active then toggle_voice(voice) end
      end
    end},
    {name = "record head", setup = function(context)
      LAYOUT.slot_with_peaks(context); LAYOUT.voices_on_slot(1, 1)
      if not S.voices[1].active then toggle_voice(1) end
      params:set("record_feedback", 50); record_buffer(1)
      context.clock.run_for(3)
    end},
    {name = "a long file's start", setup = function(context) LAYOUT.long_file_start(context, 60, 9.05) end},
    {name = "a long file's start (high, 300 s)", setup = function(context)
      LAYOUT.as_300_s_tier(); LAYOUT.long_file_start(context, 3600, 1234.56) end},
    {name = "eight slots of 4:59 (high, 300 s)", setup = function(context)
      LAYOUT.as_300_s_tier(); LAYOUT.slots_report(context, 299.4); LAYOUT.voices_on_slot(1, 2)
      S.buffer_page.field = 3; params:set("record_duration", 300)
    end},
    {name = "a recording at 1:05 (high, 300 s)", setup = function(context)
      LAYOUT.as_300_s_tier(); LAYOUT.slots_report(context, 299.4)
      context.polls.fire("bufferState", 1065)   -- slot 2 holds 1:05
      record_buffer(1)                           -- slot 1 records (for the default 8 s)
      LAYOUT.voices_on_slot(2, NUM_VOICES); S.buffer_page.slot = 2
      S.buffer_page.field = 3; params:set("record_duration", 65)
    end},
    -- long files the engine is still checking: "..." for their length, over
    -- a slot that held 4:59 (the cursor's, with every voice) and over the rest
    {name = "long files checking (high, 300 s)", setup = function(context)
      LAYOUT.as_300_s_tier(); LAYOUT.slots_report(context, 299.4)
      for slot = 1, 3 do
        local path = "/tmp/" .. LAYOUT.long_names[slot]
        context.audio.files[path] = {2, 48000 * 240, 48000}
        load_buffer(slot, path)
      end
      LAYOUT.voices_on_slot(1, NUM_VOICES)
      params:set("record_duration", 240)
    end},
  }
  for index, field in ipairs(BUFFER_FIELDS) do
    table.insert(layout_states, {name = "field " .. field.name, setup = function()
      S.buffer_page.field = index
      FIELD_VALUES[field.name]()
    end})
  end

  -- Whether the frame clock redraws the page every frame: while something
  -- drawn on the cursor slot moves (a voice's head on its audio, or its
  -- record head: S.lib.playheads.moving, #433), so the heads move at the
  -- frame rate, or a hold hint shows, so the hint changes at hold_seconds.
  -- Never while the file selector covers the page: redraw() would draw
  -- norns' file list again every frame for nothing (#435)
  local function buffer_animates()
    if PAGE.file_selector_open then return false end
    return held_hint() ~= nil or S.lib.playheads.moving(cursor_slot())
  end

  -- The page's record, at BUFFER's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc rings
  -- are lib/arc/buffer.lua's; its arc button records, as K3 does
  S.registry.pages[BUFFER_INDEX] = {name = "BUFFER", draw = redraw_buffer, hints = buffer_hints,
    enc = buffer_enc, alt_enc = buffer_alt_enc, key = buffer_key, key_release = buffer_key_release,
    alt_key = buffer_alt_key, alt_key_release = buffer_alt_key_release, enter = start_input_meter,
    leave = stop_input_meter, animates = buffer_animates,
    arc_button = record_cursor_slot, layout_states = layout_states}

  S.register_cleanup(S.constants.CLEANUP_ORDER.input_meter, function()
    stop_input_meter()
  end)

  return M
end

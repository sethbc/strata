-- lib/pages/buffer.lua
-- The BUFFER page: the selected voice and three fields (its source, the
-- record duration and level) with an input meter on the left, the eight
-- buffer slots on the right (S.BUFFER_PAGE for the layout and the file
-- selector, S.buffer_page for the cursors). E2 picks a slot, ALT+E2 a
-- field, E3 edits the field; K3 records into the cursor slot (or stops),
-- K2's release loads a file into it (the file selector, which redraw() in
-- strata.lua draws while it is open), ALT+K2 clears it and ALT+K3 saves
-- it. The input meter's polls run only while the page shows. Registers its
-- S.registry.pages record and a cleanup step; INPUT_METER,
-- input_meter_segments and the meter state are fields of this module's
-- table (S.lib.pages_buffer). The functions that were global stay global.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local NUM_VOICES = S.constants.NUM_VOICES
  local BUFFER_SECONDS = S.constants.BUFFER_SECONDS
  local UI_PAGES = S.constants.UI_PAGES
  local fileselect = require "fileselect"

  -- BUFFER page layout. Left column (x 0 to divider_x - 2): the voice's
  -- name at name_y, the three fields from field_first_y (the cursor ">" at
  -- cursor_x, the label at label_x, the value right-aligned at
  -- field_value_right), then the input meter on meter_y: "in" at label_x
  -- and eight segment_width x segment_height segments from meter_x. Right
  -- column: visible_rows slot rows from row_first_y, row_spacing apart
  -- (the list scrolls, with field_list's scroll marker at x 127): the slot
  -- number at slot_x, the name from name_x, the seconds (or REC) right-
  -- aligned at value_right; the cursor row also lists the voices reading
  -- the slot, right-aligned before its seconds, at most voices_max_width
  -- wide and never into the name's first name_min_width px (the voices
  -- shorten to "v2+" first). Strings in a row stay column_gap px apart.
  S.BUFFER_PAGE = {
    name_y = 16,
    field_first_y = 24,
    field_spacing = 8,
    cursor_x = 0,
    label_x = 5,
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
    row_first_y = 16,
    row_spacing = 7,        -- six rows at y 16-51, clear of the hint row at y 62
    visible_rows = 6,
    slot_x = 59,
    name_x = 65,
    value_right = 124,      -- clear of the scroll marker at x 127
    column_gap = 3,
    voices_max_width = 25,  -- "v2 v6" under the layout test's width estimate
    name_min_width = 12,    -- the cursor row's name keeps this much (a row with 16.0s still fits "v2+")
    file_selector_open = false,     -- K2's file selector owns the screen: redraw() draws it
    file_selector_callback = nil,   -- the callback K2 gave fileselect.enter
    script_key = nil,               -- Strata's key and enc as K2 opened the selector
    script_enc = nil
  }
  local PAGE = S.BUFFER_PAGE

  -- The cursors: slot (1..NUM_BUFFERS, what E2 picks and the keys act on)
  -- and field (1..#BUFFER_FIELDS, what ALT+E2 picks and E3 edits)
  S.buffer_page = {slot = 1, field = 1}

  -- The left column's fields: label, the param E3 edits and its value text
  local BUFFER_FIELDS = {
    {label = "src", param_id = function() return "v" .. S.selected_voice .. "_source" end,
      value = function() return voice_source_label(S.selected_voice) end},
    {label = "dur", param_id = function() return "record_duration" end,
      value = function() return string.format("%.1fs", params:get("record_duration")) end},
    {label = "lvl", param_id = function() return "record_level" end,
      value = function() return string.format("%.2f", params:get("record_level")) end},
  }

  -- The cursors, put back in range (a stray value never indexes past the
  -- slots or fields)
  local function cursor_slot()
    S.buffer_page.slot = util.clamp(math.floor(tonumber(S.buffer_page.slot) or 1), 1, NUM_BUFFERS)
    return S.buffer_page.slot
  end

  local function cursor_field()
    S.buffer_page.field = util.clamp(math.floor(tonumber(S.buffer_page.field) or 1), 1, #BUFFER_FIELDS)
    return BUFFER_FIELDS[S.buffer_page.field]
  end

  -- Show `text` (a save result, a failed load) in BUFFER's hint row
  -- for HEADER.flash_seconds (1.5 s), through the shared "hints" flash
  -- (lib/ui/flash.lua), owned by BUFFER: redraw() draws it there instead of
  -- the key hints while BUFFER is up (other pages keep their own hints), and
  -- its clock asks for a redraw when it ends
  function buffer_page_flash(text)
    S.lib.ui_flash.start("hints", text, S.constants.HEADER.flash_seconds, UI_PAGES.index.BUFFER)
  end

  -- Measured text widths, kept per string: the seconds and voices texts
  -- repeat from frame to frame, so a steady redraw measures nothing
  local measured_widths = {}
  local function text_width(text)
    local width = measured_widths[text]
    if not width then
      width = screen.text_extents(text)
      measured_widths[text] = width
    end
    return width
  end

  -- The voice's name cut to the left column, per name (the cut never
  -- changes, so it is measured once)
  local voice_names = {}
  local function voice_display_name(name)
    if not voice_names[name] then
      voice_names[name] = S.lib.ui_text.fit_text(string.upper(name), PAGE.divider_x - 2)
    end
    return voice_names[name]
  end

  -- A slot's name for the screen, cut to max_width: the file name without
  -- its extension. Cached per slot and width until the name changes (load,
  -- take, clear), so a redraw does not measure names a character at a time
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
      cache.cut[max_width] = S.lib.ui_text.fit_text(name, max_width)
    end
    return cache.cut[max_width]
  end

  -- A slot with no name (nothing loaded, recorded or remembered) shows "-";
  -- an empty one (no name, no audio reported, not recording) shows no
  -- seconds either
  local function slot_has_name(buffer)
    return buffer.name ~= "empty"
  end

  local function slot_is_empty(buffer)
    return not slot_has_name(buffer) and not buffer.recording and not (buffer.seconds > 0)
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

  -- One slot row at y: slot number, name and seconds (or REC); the cursor
  -- row is bright and also lists the voices reading the slot
  local function draw_slot_row(row, y, selected, value_right)
    local slot = row.slot
    local buffer = S.buffers[slot]
    local empty = slot_is_empty(buffer)
    local level = 2
    if selected then
      level = 15
    elseif buffer.loaded or buffer.recording then
      level = 6
    end
    screen.level(level)
    screen.move(PAGE.slot_x, y)
    screen.text(tostring(slot))
    -- names end before the seconds column (the widest seconds, "16.0s")
    local name_right = value_right - text_width(string.format("%.1fs", BUFFER_SECONDS)) - PAGE.column_gap
    if not empty then
      local seconds = buffer.recording and "REC" or string.format("%.1fs", buffer.seconds)
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
  -- held peak changed
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
      request_redraw()
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
    local v = S.voices[S.selected_voice]
    cursor_field()
    local field_cursor = S.buffer_page.field

    -- Left column: voice, the three fields, the input meter
    screen.level(15)
    screen.move(0, PAGE.name_y)
    screen.text(voice_display_name(v.name))
    for index, field in ipairs(BUFFER_FIELDS) do
      local y = PAGE.field_first_y + (index - 1) * PAGE.field_spacing
      local selected = index == field_cursor
      screen.level(selected and 15 or 4)
      if selected then
        screen.move(PAGE.cursor_x, y)
        screen.text(">")
      end
      screen.move(PAGE.label_x, y)
      screen.text(field.label)
      screen.move(PAGE.field_value_right, y)
      screen.text_right(field.value())
    end
    draw_input_meter()

    screen.level(1)
    screen.move(PAGE.divider_x, PAGE.divider_top)
    screen.line(PAGE.divider_x, PAGE.divider_bottom)
    screen.stroke()

    -- Right column: the slots, scrolled to keep one row above the cursor
    S.lib.ui_field_list.draw(slot_list_rows, cursor_slot(), {
      visible = PAGE.visible_rows, first_y = PAGE.row_first_y, spacing = PAGE.row_spacing,
      value_right = PAGE.value_right}, draw_slot_row)
  end

  -- The hint row's keys (redraw() draws the "hints" flash instead while
  -- one shows): "..." while the cursor slot's take that ended waits for the
  -- engine (K3 does nothing then)
  local function buffer_hints(alt_held)
    if alt_held then return "K2:clear K3:save" end
    local buffer = S.buffers[cursor_slot()]
    local record_hint = buffer.finishing and "..." or (buffer.recording and "stop" or "rec")
    return "K2:load K3:" .. record_hint
  end

  -- E2 picks a slot, E3 edits the field under the field cursor
  local function buffer_enc(n, d)
    if n == 2 then
      S.buffer_page.slot = util.clamp(cursor_slot() + d, 1, NUM_BUFFERS)
    elseif n == 3 then
      enc_param_delta(n, cursor_field().param_id(), d)
    end
  end

  -- ALT+E2 moves the field cursor; ALT+E3 goes on to buffer_enc (fine
  -- adjustment, through enc_param_delta)
  local function buffer_alt_enc(n, d)
    if n ~= 2 then return false end
    cursor_field()
    S.buffer_page.field = util.clamp(S.buffer_page.field + d, 1, #BUFFER_FIELDS)
    return true
  end

  -- K3 (press) and the arc's button record into the cursor slot, or stop
  -- early while it records. K2 acts on release (buffer_key_release)
  local function record_cursor_slot()
    record_buffer(cursor_slot())
  end

  local function buffer_key(n)
    if n == 3 then record_cursor_slot() end
  end

  -- Save the cursor slot, confirmed in the hint row: a slot recording or
  -- awaiting its take is busy (nothing to save yet); otherwise save_buffer
  -- saves only a slot the engine reports holding audio
  local function save_cursor_slot()
    local slot = cursor_slot()
    local buffer = S.buffers[slot]
    if buffer.recording or buffer.finishing then
      buffer_page_flash("buf " .. slot .. " busy")
      return
    end
    local has_audio = buffer.seconds > 0
    save_buffer(slot)
    buffer_page_flash(has_audio and ("saved buf " .. slot) or ("buf " .. slot .. " empty"))
  end

  -- ALT+K2 clears the cursor slot, ALT+K3 saves it. An ALT press releases
  -- through alt_key_release (none here), never key_release, so ALT+K2
  -- never opens the file selector, even when K1 comes up first
  local function buffer_alt_key(n)
    if n == 2 then
      clear_buffer(cursor_slot())
    elseif n == 3 then
      save_cursor_slot()
    end
  end

  -- K2 released: open the file selector for the cursor slot
  local function buffer_key_release(n)
    if n ~= 2 then return end
    local slot = cursor_slot()
    -- the selector takes every key while open, so keys held now are released
    -- there, never reaching key(): forget them
    forget_held_keys()
    -- From play mode norns puts Strata's redraw back while the selector is
    -- open (fs.enter calls norns.menu.init), so Strata's redraws would draw
    -- over the file list: until the callback, which norns calls on a choice
    -- and on a cancel alike, they draw the selector instead
    local function file_chosen(path)
      -- loaded directly (it also shows the path in buf<n>_file): setting the
      -- param would do nothing when it already holds this path
      if path ~= "cancel" then
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

  -- The states the layout tests and the page renders draw (each on a fresh
  -- script with BUFFER shown)
  local LONG_NAMES = {"WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
    "café_crème_très_longue.wav", "no_extension_but_long", "drone", "field_rec.flac"}

  local function load_long_names(context)
    for slot = 1, NUM_BUFFERS do
      load_buffer(slot, "/tmp/" .. LONG_NAMES[(slot - 1) % #LONG_NAMES + 1])
      context.polls.fire("bufferState", (slot - 1) * 100 + BUFFER_SECONDS)
    end
  end

  local function voices_on_slot(slot, count)
    for voice = 1, count do params:set("v" .. voice .. "_source", slot + 1) end
  end

  local BUFFER_INDEX = UI_PAGES.index.BUFFER
  local layout_states = {
    {name = "slot 1", setup = function(context) load_long_names(context); voices_on_slot(1, 2) end},
    {name = "slot 8", setup = function(context)
      load_long_names(context); voices_on_slot(8, 2); S.buffer_page.slot = NUM_BUFFERS end},
    {name = "field dur", setup = function() S.buffer_page.field = 2; params:set("record_duration", BUFFER_SECONDS) end},
    {name = "field lvl", setup = function() S.buffer_page.field = 3; params:set("record_level", 0.5) end},
    {name = "long names", setup = function(context)
      load_long_names(context); voices_on_slot(4, NUM_VOICES); S.buffer_page.slot = 4 end},
    {name = "every slot recording", setup = function()
      for slot = 1, NUM_BUFFERS do record_buffer(slot) end
      voices_on_slot(1, 1)
    end},
    {name = "saved flash", setup = function(context)
      load_long_names(context); alt_action(BUFFER_INDEX, 3) end},
    {name = "busy flash", setup = function() record_buffer(1); alt_action(BUFFER_INDEX, 3) end},
    {name = "empty flash", setup = function() alt_action(BUFFER_INDEX, 3) end},
    {name = "load failed flash", setup = function() buffer_page_flash("buf 8 load failed") end},
    {name = "meter peak", setup = function(context)
      context.polls.fire("amp_in_l", 1); context.polls.fire("amp_in_r", 0.2)
      context.polls.fire("amp_in_l", 0.05)
    end},
  }

  -- The page's record, at BUFFER's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc rings
  -- are lib/arc/buffer.lua's; its arc button records, as K3 does
  S.registry.pages[BUFFER_INDEX] = {name = "BUFFER", draw = redraw_buffer, hints = buffer_hints,
    enc = buffer_enc, alt_enc = buffer_alt_enc, key = buffer_key, key_release = buffer_key_release,
    alt_key = buffer_alt_key, enter = start_input_meter, leave = stop_input_meter,
    arc_button = record_cursor_slot, layout_states = layout_states}

  S.register_cleanup(S.constants.CLEANUP_ORDER.input_meter, function()
    stop_input_meter()
  end)

  return M
end

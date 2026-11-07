-- lib/pages/buffer.lua
-- The BUFFER page: the selected voice's source and the eight buffer slots
-- (S.BUFFER_PAGE), E2 voice, E3 source, K3 record/stop, K2+K3 save, K2
-- release load (the file selector, which redraw() in strata.lua draws
-- while it is open). Registers its S.registry.pages record. The functions
-- that were global stay global.

return function(S)
  local M = {}
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local UI_PAGES = S.constants.UI_PAGES
  local fileselect = require "fileselect"

  -- BUFFER page: the selected voice and its source on the left, the eight
  -- buffer slots on the right (slot, name or "empty", seconds or REC)
  S.BUFFER_PAGE = {
    row_first_y = 14,
    row_spacing = 6,        -- eight rows at y 14-56, clear of the hint row at y 62
    slot_x = 65,
    name_x = 71,
    name_max_width = 31,    -- the name ends before the widest seconds ("16.0s" from x 103)
    flash_seconds = 1.5,    -- a transient hint (the K2+K3 save result) shows this long
    flash_text = nil,       -- the transient hint, drawn instead of the key hints
    flash_until = 0,        -- util.time() when it ends
    flash_clock = nil,      -- asks for a redraw when it ends
    file_selector_open = false,     -- K2's file selector owns the screen: redraw() draws it
    file_selector_callback = nil,   -- the callback K2 gave fileselect.enter
    script_key = nil,               -- Strata's key and enc as K2 opened the selector
    script_enc = nil
  }

  -- Show `text` in the BUFFER page's hint row for BUFFER_PAGE.flash_seconds.
  -- redraw_buffer stops drawing it at flash_until; the clock clears it (even
  -- if it wakes a little early) and asks for a redraw so it goes away untouched.
  function buffer_page_flash(text)
    S.BUFFER_PAGE.flash_text = text
    S.BUFFER_PAGE.flash_until = util.time() + S.BUFFER_PAGE.flash_seconds
    cancel_buffer_page_flash_clock()
    S.BUFFER_PAGE.flash_clock = clock.run(function()
      clock.sleep(S.BUFFER_PAGE.flash_seconds)
      S.BUFFER_PAGE.flash_clock = nil
      S.BUFFER_PAGE.flash_text = nil
      request_redraw()
    end)
  end

  function cancel_buffer_page_flash_clock()
    if S.BUFFER_PAGE.flash_clock then
      clock.cancel(S.BUFFER_PAGE.flash_clock)
      S.BUFFER_PAGE.flash_clock = nil
    end
  end

  -- A buffer's name for the screen: the file name without its extension, cut
  -- to fit. Cached per slot until the name changes (load, take, clear), so a
  -- redraw does not measure eight names a character at a time.
  local function buffer_display_name(slot)
    local buffer = S.buffers[slot]
    if buffer.display_name_of ~= buffer.name then
      local name = buffer.name:gsub("%.[^.]*$", "")
      if name == "" then name = buffer.name end
      buffer.display_name = S.lib.ui_text.fit_text(name, S.BUFFER_PAGE.name_max_width)
      buffer.display_name_of = buffer.name
    end
    return buffer.display_name
  end

  function redraw_buffer()
    local v = S.voices[S.selected_voice]
    local voice_slot = voice_buffer_slot(S.selected_voice)

    -- Left column (0-60px): voice, source, recording settings
    screen.level(15)
    screen.move(0, 18)
    screen.text(string.upper(v.name))
    screen.level(10)
    screen.move(0, 26)
    screen.text("src: " .. voice_source_label(S.selected_voice))
    screen.level(4)
    screen.move(0, 42)
    screen.text("dur: " .. string.format("%.1f", params:get("record_duration")) .. "s")
    screen.move(0, 50)
    screen.text("lvl: " .. string.format("%.2f", params:get("record_level")))

    screen.level(1)
    screen.move(62, 10)
    screen.line(62, 56)
    screen.stroke()

    -- Right column (65-127px): one row per buffer slot. The voice's buffer is
    -- brightest, loaded (or recording) slots mid, empty slots dim.
    for slot = 1, NUM_BUFFERS do
      local buffer = S.buffers[slot]
      local y = S.BUFFER_PAGE.row_first_y + (slot - 1) * S.BUFFER_PAGE.row_spacing
      local level = 2
      if slot == voice_slot then
        level = 15
      elseif buffer.loaded or buffer.recording then
        level = 8
      end
      screen.level(level)
      screen.move(S.BUFFER_PAGE.slot_x, y)
      screen.text(tostring(slot))
      screen.move(S.BUFFER_PAGE.name_x, y)
      screen.text(buffer_display_name(slot))
      screen.move(127, y)
      screen.text_right(buffer.recording and "REC" or string.format("%.1fs", buffer.seconds))
    end

    if S.BUFFER_PAGE.flash_text and util.time() < S.BUFFER_PAGE.flash_until then
      draw_hints(S.BUFFER_PAGE.flash_text)
    elseif voice_slot then
      -- "..." while a take that ended waits for the engine (K3 does nothing)
      local voice_buffer = S.buffers[voice_slot]
      local record_hint = voice_buffer.finishing and "..." or (voice_buffer.recording and "stop" or "rec")
      draw_hints("K2:load K3:" .. record_hint .. " K2+3:save")
    else
      -- K2 and K3 need a buffer source; E3 picks one
      draw_hints("K2:- K3:- E3:source")
    end
  end

  local function buffer_enc(n, d)
    if n == 2 then
      S.lib.ui_keys.select_voice_by(d)
    elseif n == 3 then
      params:delta("v" .. S.selected_voice .. "_source", d)
    end
  end

  -- K3 while K2 is held saved the buffer: K2's release then opens nothing
  S.buffer_saved_during_k2 = false

  -- K3 (press) records into the voice's buffer, or stops early; with K2 held
  -- it saves the buffer instead. K2 acts on release (buffer_key_release).
  -- Both do nothing when the voice's source is not a buffer.
  local function buffer_key(n)
    if n == 2 then
      S.buffer_saved_during_k2 = false
    elseif n == 3 then
      local slot = voice_buffer_slot(S.selected_voice)
      if not slot then return end
      if S.key_press_page[2] == S.ui_page then
        -- a slot recording or awaiting its take is busy: nothing to save yet.
        -- Otherwise save_buffer saves only a slot the engine reports holding audio
        local buffer = S.buffers[slot]
        if buffer.recording or buffer.finishing then
          buffer_page_flash("buf " .. slot .. " busy")
        else
          local has_audio = buffer.seconds > 0
          save_buffer(slot)
          buffer_page_flash(has_audio and ("saved buf " .. slot) or ("buf " .. slot .. " empty"))
        end
        S.buffer_saved_during_k2 = true
      else
        record_buffer(slot)
      end
    end
  end



  -- K2 released: open the file selector for the voice's buffer, unless K3
  -- saved while K2 was down
  local function buffer_key_release(n)
    if n ~= 2 then return end
    if S.buffer_saved_during_k2 then
      S.buffer_saved_during_k2 = false
      return
    end
    local slot = voice_buffer_slot(S.selected_voice)
    if not slot then return end
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
    S.BUFFER_PAGE.file_selector_open = true
    S.BUFFER_PAGE.file_selector_callback = file_chosen
    S.BUFFER_PAGE.script_key, S.BUFFER_PAGE.script_enc = key, enc
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
      key, enc = S.BUFFER_PAGE.script_key, S.BUFFER_PAGE.script_enc
      close_buffer_file_selector()
      if not norns.menu.status() then pcall(norns.menu.init) end
      error(enter_error, 0)
    end
  end

  -- The BUFFER K2 selector is closed (its callback ran) or will never call back
  function close_buffer_file_selector()
    S.BUFFER_PAGE.file_selector_open = false
    S.BUFFER_PAGE.file_selector_callback = nil
    S.BUFFER_PAGE.script_key, S.BUFFER_PAGE.script_enc = nil, nil
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
    if not S.BUFFER_PAGE.file_selector_open or not norns.menu.status() then return end
    if fileselect.callback == nil then return end
    if fileselect.callback == S.BUFFER_PAGE.file_selector_callback then return end
    key, enc = S.BUFFER_PAGE.script_key, S.BUFFER_PAGE.script_enc
    close_buffer_file_selector()
  end

  -- The page's record, at BUFFER's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Only BUFFER
  -- acts on key releases
  for index, name in ipairs(UI_PAGES) do
    if name == "BUFFER" then
      S.registry.pages[index] = {name = name, draw = redraw_buffer, enc = buffer_enc, key = buffer_key,
        key_release = buffer_key_release}
    end
  end

  S.register_cleanup(S.constants.CLEANUP_ORDER.buffer_page_flash, function()
    cancel_buffer_page_flash_clock()
  end)

  return M
end

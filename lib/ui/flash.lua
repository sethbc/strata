-- lib/ui/flash.lua
-- Transient texts (S.lib.ui_flash). Two slots: "header" replaces the
-- header's page dots and indicators (draw_header), "hints" replaces the
-- hint row (redraw() in strata.lua). A flash started for a page shows only
-- while that page is up, so a prompt never sits over another page's keys.
-- header_flash and
-- buffer_page_flash (lib/pages/buffer.lua) start them; the functions that
-- are global stay global. Under the flashes, a slot shows a module's
-- standing notice while its state lasts (add_notice: MOD's learn).

return function(S)
  local M = {}
  local HEADER = S.constants.HEADER

  -- Per slot: the text (nil when none), ends_at (util.time() when it stops
  -- showing), page (the UI_PAGES index it belongs to, nil for every page)
  -- and the clock that ends it. Tests read the clocks here
  M.slots = {header = {ends_at = 0}, hints = {ends_at = 0}}

  local function slot_state(slot)
    local state = M.slots[slot]
    assert(state, "no flash slot " .. tostring(slot))
    return state
  end

  local function cancel_clock(state)
    if state.clock then
      clock.cancel(state.clock)
      state.clock = nil
    end
  end

  -- Show `text` in `slot` for `seconds` (HEADER.flash_seconds if nil), on
  -- page `page` only (a UI_PAGES index; nil: whatever page is up). A new
  -- flash in a slot replaces the one showing and cancels its clock first; a
  -- nil text just ends the one showing. text() stops returning it at
  -- ends_at; the clock clears it (even if it wakes a little early) and asks
  -- for a redraw, so it goes away untouched.
  function M.start(slot, text, seconds, page)
    local state = slot_state(slot)
    seconds = seconds or HEADER.flash_seconds
    cancel_clock(state)
    request_redraw()
    if text == nil then
      state.text, state.page = nil, nil
      return
    end
    state.text = tostring(text)
    state.page = page
    state.ends_at = util.time() + seconds
    state.clock = clock.run(function()
      clock.sleep(seconds)
      state.clock = nil
      state.text = nil
      request_redraw()
    end)
  end

  -- Standing notices (3.4): per slot, functions a module adds that return a
  -- text while what they tell stands (MOD's learn waiting for a touch,
  -- ruling 80), else nil. A slot shows its first standing notice on every
  -- page whenever no flash shows in it, for exactly as long as the state
  -- lasts: a notice has no clock, and whatever ends the state asks for the
  -- redraw
  local notices = {}
  for slot in pairs(M.slots) do notices[slot] = {} end

  function M.add_notice(slot, text_fn)
    slot_state(slot)
    assert(type(text_fn) == "function", "a notice is a function")
    table.insert(notices[slot], text_fn)
  end

  local function notice_text(slot)
    for _, text_fn in ipairs(notices[slot]) do
      local text = text_fn()
      if text ~= nil then return tostring(text) end
    end
    return nil
  end

  -- What the slot shows: its flash while it shows (and its page, if it has
  -- one, is up), else its first standing notice, else nil
  function M.text(slot)
    local state = slot_state(slot)
    local flashing = state.text ~= nil and util.time() < state.ends_at and not (state.page and state.page ~= S.ui_page)
    if flashing then return state.text end
    return notice_text(slot)
  end

  function M.cancel_all()
    for _, state in pairs(M.slots) do
      cancel_clock(state)
      state.text = nil
    end
  end

  -- A transient value in the header (a tempo set from the grid, ...)
  function header_flash(text)
    M.start("header", text, HEADER.flash_seconds)
  end

  S.register_cleanup(S.constants.CLEANUP_ORDER.ui_flash, function()
    M.cancel_all()
  end)

  -- A flash showing a text has the clock that ends it
  S.register_invariant("flash slots", function()
    for slot, state in pairs(M.slots) do
      if state.text ~= nil and state.clock == nil then return slot .. " shows '" .. state.text .. "' with no clock" end
    end
  end)

  return M
end

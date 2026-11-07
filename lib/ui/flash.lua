-- lib/ui/flash.lua
-- Transient texts (S.lib.ui_flash). Two slots: "header" replaces the
-- header's page dots and indicators (draw_header), "hints" replaces the
-- hint row on every page (redraw() in strata.lua). header_flash and
-- buffer_page_flash (lib/pages/buffer.lua) start them; the functions that
-- are global stay global.

return function(S)
  local M = {}
  local HEADER = S.constants.HEADER

  -- Per slot: the text (nil when none), ends_at (util.time() when it stops
  -- showing) and the clock that ends it. Tests read the clocks here
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

  -- Show `text` in `slot` for `seconds` (HEADER.flash_seconds if nil). A new
  -- flash in a slot replaces the one showing and cancels its clock first.
  -- text() stops returning it at ends_at; the clock clears it (even if it
  -- wakes a little early) and asks for a redraw, so it goes away untouched.
  function M.start(slot, text, seconds)
    local state = slot_state(slot)
    seconds = seconds or HEADER.flash_seconds
    cancel_clock(state)
    state.text = tostring(text)
    state.ends_at = util.time() + seconds
    state.clock = clock.run(function()
      clock.sleep(seconds)
      state.clock = nil
      state.text = nil
      request_redraw()
    end)
    request_redraw()
  end

  -- The slot's text while it shows, else nil
  function M.text(slot)
    local state = slot_state(slot)
    if state.text and util.time() < state.ends_at then return state.text end
    return nil
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

  return M
end

-- lib/ui/frame.lua
-- Screen and arc redraw requests and the frame clock. The runtime fields
-- (screen_dirty, arc_dirty, frame_clock, draw_errors) stay on the shared
-- S.constants.UI_PAGES table. The functions are global, as before.

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  S.ui_page = 1  -- index into UI_PAGES


  -- Screen and arc redraws. Anything that changes what they show calls
  -- request_redraw(); the frame clock (started by init, canceled by cleanup)
  -- then draws whichever is dirty, at most FRAMES_PER_SECOND times a second,
  -- so a burst of arc turns, MIDI or param changes costs one frame. Handlers
  -- never draw directly. The global redraw() still draws at once when norns
  -- calls it (e.g. as its menu closes).
  UI_PAGES.FRAMES_PER_SECOND = 15
  UI_PAGES.screen_dirty = true  -- the first frame draws both
  UI_PAGES.arc_dirty = true
  UI_PAGES.frame_clock = nil

  function request_redraw()
    UI_PAGES.screen_dirty = true
    UI_PAGES.arc_dirty = true
  end

  -- Run one draw of a frame (`part` names it: "screen" or "arc"). An error is
  -- printed with its traceback instead of ending the frame clock, so one
  -- failing frame never freezes the display: the next request draws again. A
  -- draw that keeps failing with the same error prints it once, not on every
  -- frame; another error, or the same one after a good draw, prints again.
  UI_PAGES.draw_errors = {}  -- per part: the error message it last printed

  -- xpcall handler for a frame draw: a key that stays the same while the
  -- error does, and the error with its traceback. A string error is its own
  -- key. A table error is a new table each time, so its key is its `message`
  -- field (also what is printed) or, without one, its type.
  function draw_error_report(message)
    local text, key = tostring(message), type(message)
    if type(message) == "string" then
      key = message
    elseif type(message) == "table" and type(message.message) == "string" then
      text, key = message.message, message.message
    end
    return {message = key, traceback = debug.traceback(text, 2)}
  end

  function draw_frame_part(part, draw)
    local drawn, report = xpcall(draw, draw_error_report)
    if drawn then
      UI_PAGES.draw_errors[part] = nil
    elseif report.message ~= UI_PAGES.draw_errors[part] then
      UI_PAGES.draw_errors[part] = report.message
      print("strata: frame draw failed: " .. report.traceback)
    end
  end

  -- One frame. It calls the global redraw(), so norns' swaps apply: nothing
  -- while its menu is open (redraw is norns.none then; norns redraws as the
  -- menu closes), and the file list while the file selector is open (redraw()
  -- never draws the page then). The LFO page draws every frame: its dots move.
  -- Each flag clears before its draw, so a failed draw is not retried.
  function draw_frame()
    if UI_PAGES[S.ui_page] == "LFO" then UI_PAGES.screen_dirty = true end
    if UI_PAGES.screen_dirty then
      UI_PAGES.screen_dirty = false
      draw_frame_part("screen", redraw)
    end
    if UI_PAGES.arc_dirty then
      UI_PAGES.arc_dirty = false
      draw_frame_part("arc", arc_redraw)
    end
  end

  function start_frame_clock()
    stop_frame_clock()
    UI_PAGES.frame_clock = clock.run(function()
      while true do
        clock.sleep(1 / UI_PAGES.FRAMES_PER_SECOND)
        draw_frame()
      end
    end)
  end

  function stop_frame_clock()
    if UI_PAGES.frame_clock then
      clock.cancel(UI_PAGES.frame_clock)
      UI_PAGES.frame_clock = nil
    end
  end

  return M
end

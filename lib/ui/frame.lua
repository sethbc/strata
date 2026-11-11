-- lib/ui/frame.lua
-- Screen and arc redraw requests and the frame clock. The runtime fields
-- (screen_dirty, arc_dirty, frame_clock, draw_errors) stay on the shared
-- S.constants.UI_PAGES table. The functions are global, as before, but for
-- contained_call, the error containment of every clock step, a field of
-- this module's table (S.lib.ui_frame).

return function(S)
  local M = {}
  local UI_PAGES = S.constants.UI_PAGES

  S.ui_page = 1  -- index into UI_PAGES

  -- False until init's first start step (START_ORDER.started). norns can
  -- route keys, encoders and redraw() to the script before init (the menu
  -- closed while the engine loads): redraw, key and enc in strata.lua do
  -- nothing until it is set (#426)
  S.started = false
  S.register_start(S.constants.START_ORDER.started, function()
    S.started = true
  end)

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

  -- The screen alone, for a change no arc ring shows that comes often (the
  -- BUFFER input meter's level): the next frame draws the screen and leaves
  -- a connected arc alone, as an animating page's frames do (#434)
  function M.request_screen_redraw()
    UI_PAGES.screen_dirty = true
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

  -- fn(...) under xpcall with draw_error_report, for every step a clock or
  -- the lattice runs (a frame's draw, the playhead tick's parts, an LFO
  -- step, a glide step, a mutation tick): a failure prints "strata: <label>
  -- failed: " and the traceback once per distinct message for its key
  -- (errors[key] holds the message last printed), a success forgets the
  -- key's message. Returns whether fn ran without an error
  function M.contained_call(errors, key, label, fn, ...)
    local ran, report = xpcall(fn, draw_error_report, ...)
    if ran then
      errors[key] = nil
    elseif report.message ~= errors[key] then
      errors[key] = report.message
      print("strata: " .. label .. " failed: " .. report.traceback)
    end
    return ran
  end

  function draw_frame_part(part, draw)
    M.contained_call(UI_PAGES.draw_errors, part, "frame draw", draw)
  end

  -- Whether the shown page animates: its record's animates(), run through
  -- contained_call (key "animates"), so an error there counts as false and
  -- prints once instead of ending the frame clock (#320)
  local animating = false  -- what read_animates found
  local function read_animates(record)
    animating = record.animates() and true or false
  end
  local function page_animates()
    local record = S.registry.pages[S.ui_page]
    if not (record and record.animates) then return false end
    animating = false
    return M.contained_call(UI_PAGES.draw_errors, "animates", "page animates", read_animates, record) and animating
  end

  -- One frame. It calls the global redraw(), so norns' swaps apply: nothing
  -- while its menu is open (redraw is norns.none then; norns redraws as the
  -- menu closes), and the file list while the file selector is open (redraw()
  -- never draws the page then). A page whose record has animates()
  -- returning true draws every frame (LFO's dots move while an LFO runs,
  -- SEQ's column while the patterns play, BUFFER's heads and held-key hint,
  -- SCENES' overwrite prompt until it lapses). They mark the screen only:
  -- the arc shows nothing that moves with them. Each flag clears before its
  -- draw, so a failed draw is not retried.
  function draw_frame()
    if page_animates() then UI_PAGES.screen_dirty = true end
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
        -- the whole frame contained too (key "frame"): nothing in a frame
        -- ends the clock (#320)
        M.contained_call(UI_PAGES.draw_errors, "frame", "frame", draw_frame)
      end
    end)
  end

  function stop_frame_clock()
    if UI_PAGES.frame_clock then
      clock.cancel(UI_PAGES.frame_clock)
      UI_PAGES.frame_clock = nil
    end
  end

  -- From init's frame clock step on (START_ORDER.frame_clock; the peaks
  -- loop and the playhead clock start after it) the screen and arc draw at
  -- FRAMES_PER_SECOND
  S.register_start(S.constants.START_ORDER.frame_clock, function()
    start_frame_clock()
  end)

  S.register_cleanup(S.constants.CLEANUP_ORDER.frame_clock, function()
    stop_frame_clock()
  end)

  return M
end

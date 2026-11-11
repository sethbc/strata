-- test/unit/ui_test.lua
-- The shared UI: page selection (E1), keys and the norns menu, the frame
-- clock and redraws (lib/ui/)
-- Run alone: lua test/run.lua ui

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value = h.load_strata, h.find_upvalue, h.local_value
local next_frame, finish_startup, wake_buffer_clock = h.next_frame, h.finish_startup, h.wake_buffer_clock
local deep_copy, PAGE_TITLES, show_page = h.deep_copy, h.PAGE_TITLES, h.show_page
local count_screen_draws, screen_shows = h.count_screen_draws, h.screen_shows
local assert_drawn_on_next_frame, tap = h.assert_drawn_on_next_frame, h.tap

test("E1 steps one page per detent: no acceleration, 4 ticks per page", function()
  local context = load_strata()
  local encoders = context.encoders
  assert_equal(encoders.accel[1], false, "E1 acceleration off")
  assert_equal(encoders.sens[1], 4, "E1 needs 4 ticks per page")
  assert_equal(encoders.accel[2], true, "E2 keeps norns' default acceleration")
  assert_equal(encoders.accel[3], true, "E3 keeps norns' default acceleration")
  -- a fast turn (1 ms between ticks) of 4 ticks moves exactly one page
  for _ = 1, 4 do encoders.deliver(1, 1, 0.001) end
  assert_equal(local_value("ui_page"), 2, "fast E1 turn does not skip pages")
  for _ = 1, 3 do encoders.deliver(1, 1, 0.001) end
  assert_equal(local_value("ui_page"), 2, "three ticks are not yet a page")
  encoders.deliver(1, 1, 0.001)
  assert_equal(local_value("ui_page"), 3, "the fourth tick is")
  for _ = 1, 8 do encoders.deliver(1, -1, 0.001) end
  assert_equal(local_value("ui_page"), 1, "eight ticks back return two pages")
end)

test("every encoder, key and arc control is safe on every page; the arc button acts only through arc_button", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  context.grid.plug(1, 16, 16)
  for page = 1, #PAGE_TITLES do
    show_page(page)
    for _, n in ipairs({ 2, 3 }) do
      enc(n, 1); enc(n, -1)
      assert_equal(local_value("ui_page"), page, "E" .. n .. " stays on " .. PAGE_TITLES[page])
    end
    for n = 1, 3 do key(n, 1); key(n, 0) end
    for ring = 1, 4 do context.arc.turn(1, ring, 5); context.arc.turn(1, ring, -5) end
    arc_redraw()
    -- the button check covers only pages without arc_button (all but MAIN
    -- today): there it leaves voices and locks alone
    if not local_value("S").registry.pages[page].arc_button then
      local frozen = deep_copy(local_value("frozen"))
      local active = {}
      for voice_idx, voice in ipairs(local_value("voices")) do active[voice_idx] = voice.active end
      context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
      for voice_idx, voice in ipairs(local_value("voices")) do
        assert_equal(voice.active, active[voice_idx], "arc button leaves voices alone on " .. PAGE_TITLES[page])
        assert_equal(local_value("frozen")[voice_idx], frozen[voice_idx], "arc button leaves lock alone on " .. PAGE_TITLES[page])
      end
    end
  end
  -- SETUP: arc rings do nothing
  show_page("SETUP")
  local density = params:get("master_density")
  context.arc.turn(1, 1, 40)
  assert_equal(params:get("master_density"), density, "arc ring 1 does not change density on SETUP")
end)

test("the frame clock draws the screen and arc at 15 fps, only when asked (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local pages = local_value("UI_PAGES")
  assert_equal(pages.FRAMES_PER_SECOND, 15, "one named frame rate")
  local frame_clock = pages.frame_clock
  assert_true(context.clock.threads[frame_clock] ~= nil, "init starts the frame clock")
  next_frame(context)
  local sleeps = context.clock.sleep_log
  assert_equal(sleeps[#sleeps].id, frame_clock)
  assert_near(sleeps[#sleeps].amount, 1 / 15, 1e-9, "a frame every 1/15 s")
  -- nothing changed since the last frame: nothing is drawn
  local counter = count_screen_draws()
  local arc_refreshes = arc_hardware.refresh_count
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "an idle frame leaves the screen alone")
  assert_equal(arc_hardware.refresh_count, arc_refreshes, "and the arc")
  -- steps of a running LFO (the library writes its scaled and raw text
  -- params) and the drift of a synth voice's grain pitch show nowhere
  params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  next_frame(context)
  counter = count_screen_draws()
  context.lfo.tick(local_value("lfos")[1], 0.7)
  local drift_metro = local_value("drift_metro")
  drift_metro.event()
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "LFO steps and grain pitch drift ask for no redraw")
  -- a drifting buffer position shows on MAIN
  params:set("v1_source", 2)
  next_frame(context)
  counter = count_screen_draws()
  drift_metro.event()
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "a buffer voice's drifting position redraws")
  -- norns' own redraw() (e.g. as its menu closes) still draws the page
  context.screen.texts = {}
  redraw()
  assert_true(screen_shows(context, "MAIN"), "redraw() draws the current page at once")
  cleanup()
  assert_equal(context.clock.threads[frame_clock], nil, "cleanup cancels the frame clock")
end)

test("a drifting buffer position redraws only for the selected voice (#49)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  local voices = local_value("voices")
  assert_true(voices[2].active, "voice 2 runs")
  params:set("v2_source", 3)  -- voice 2 drifts its buffer position; voice 1 (selected) is a synth
  params:set("v2_buf_pos", 0.5)  -- away from the ends, so every drift step moves it
  local drift_metro = local_value("drift_metro")
  for page = 1, #PAGE_TITLES do
    show_page(page)
    next_frame(context)
    local counter = count_screen_draws()
    local arc_refreshes = arc_hardware.refresh_count
    local position = params:get("v2_buf_pos")
    drift_metro.event()
    next_frame(context)
    counter.restore()
    assert_true(params:get("v2_buf_pos") ~= position, "voice 2's position drifted")
    -- the LFO page draws every frame anyway
    if PAGE_TITLES[page] ~= "LFO" then
      assert_equal(counter.screen, 0, PAGE_TITLES[page] .. ": an unselected voice's drift draws nothing")
    end
    assert_equal(arc_hardware.refresh_count, arc_refreshes, PAGE_TITLES[page] .. ": nor the arc")
  end
  -- selected, its drift shows on MAIN and the BUFFER page's arc ring
  show_page("MAIN"); enc(2, 1)
  assert_equal(local_value("selected_voice"), 2)
  next_frame(context)
  local counter = count_screen_draws()
  drift_metro.event()
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "the selected voice's drift redraws")
end)

test("a draw that fails prints the error and the frame clock keeps drawing (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  next_frame(context)
  local frame_clock = local_value("UI_PAGES").frame_clock
  local real_redraw, real_arc_redraw = redraw, arc_redraw
  local screen_draws = 0
  redraw = function() error("screen draw failed") end
  arc_redraw = function() error("arc draw failed") end
  request_redraw()
  context.printed = {}
  next_frame(context)
  redraw = function() screen_draws = screen_draws + 1; real_redraw() end
  arc_redraw = real_arc_redraw
  assert_true(context.clock.threads[frame_clock] ~= nil, "the frame clock survives the failed draws")
  local output = table.concat(context.printed, "\n")
  assert_true(output:find("screen draw failed", 1, true), "the screen error is printed")
  assert_true(output:find("arc draw failed", 1, true), "the arc error is printed")
  assert_true(output:find("stack traceback", 1, true), "with a traceback")
  -- the failed frame cleared its flags: nothing is retried until asked
  local arc_refreshes = arc_hardware.refresh_count
  next_frame(context)
  assert_equal(screen_draws, 0, "a failed frame is not retried on its own")
  request_redraw()
  next_frame(context)
  redraw = real_redraw
  assert_equal(screen_draws, 1, "the next request draws the screen again")
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "and the arc")
end)

-- The one helper every contained clock step uses (frame, playheads, LFOs,
-- glide, mutation): an xpcall with draw_error_report, a failure printed
-- once per message for its key, a success forgetting it (#517)
test("contained_call prints a failure once per message and key, and again after a success", function()
  local context = load_strata()
  local contained_call = local_value("S").lib.ui_frame.contained_call
  local errors = {}
  local function failing(message) error(message) end
  local function reports(text)
    local count = 0
    for _, line in ipairs(context.printed) do
      if line:find("strata: probe failed: ", 1, true) == 1 and line:find(text, 1, true) then count = count + 1 end
    end
    return count
  end
  context.printed = {}
  assert_equal(contained_call(errors, "a", "probe", failing, "boom"), false, "a failure returns false")
  assert_equal(contained_call(errors, "a", "probe", failing, "boom"), false)
  assert_equal(reports("boom"), 1, "the same message prints once")
  assert_true(context.printed[1]:find("stack traceback", 1, true), "with its traceback")
  contained_call(errors, "b", "probe", failing, "boom")
  assert_equal(reports("boom"), 2, "another key prints its own")
  contained_call(errors, "a", "probe", failing, "bang")
  assert_equal(reports("bang"), 1, "a new message prints at once")
  local sum
  assert_equal(contained_call(errors, "a", "probe", function(x, y) sum = x + y end, 2, 3), true, "a success returns true")
  assert_equal(sum, 5, "the arguments reach the function")
  assert_equal(errors.a, nil, "and the key's message is forgotten")
  contained_call(errors, "a", "probe", failing, "bang")
  assert_equal(reports("bang"), 2, "so the same message prints again")
  assert_equal(errors.b ~= nil, true, "another key keeps its own")
end)

-- The lines context.printed holds that contain `text`
local function lines_printed(context, text)
  local count = 0
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then count = count + 1 end
  end
  return count
end

-- A page's animates() runs inside the frame's containment: an error there
-- counts as false, prints once, and the frame clock keeps drawing (#320)
test("an animates() that fails prints once, counts as false, and the frame clock keeps drawing (#320)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("SEQ")
  local record = S.registry.pages[S.ui_page]
  local frame_clock = S.constants.UI_PAGES.frame_clock
  local real_animates = record.animates
  record.animates = function() error("animates boom") end
  context.printed = {}
  context.clock.run_for(0.2)
  local counter = count_screen_draws()
  context.clock.run_for(1)
  assert_true(context.clock.threads[frame_clock] ~= nil, "the frame clock survives the failing animates()")
  assert_equal(lines_printed(context, "animates boom"), 1, "the error prints once in a second of frames")
  assert_equal(counter.screen, 0, "a failing animates() counts as false: nothing draws unasked")
  request_redraw(); next_frame(context)
  assert_equal(counter.screen, 1, "a request still draws")
  record.animates = function() return true end
  context.clock.run_for(0.1)  -- half a frame past the last one, so a second holds 15 whole frames
  counter.screen = 0
  context.clock.run_for(1)
  counter.restore()
  record.animates = real_animates
  assert_equal(counter.screen, 15, "animates() true again draws every frame")
end)

-- The frame clock's body is contained too: nothing in a frame ends it (#320)
test("a frame that fails outside its draws prints once and the frame clock keeps running (#320)", function()
  local context = load_strata(); finish_startup(context)
  local frame_clock = local_value("UI_PAGES").frame_clock
  local real_draw_frame = draw_frame
  draw_frame = function() error("frame boom") end
  context.printed = {}
  context.clock.run_for(1)
  draw_frame = real_draw_frame
  assert_true(context.clock.threads[frame_clock] ~= nil, "the frame clock survives")
  assert_equal(lines_printed(context, "frame boom"), 1, "the error prints once in a second of frames")
  local counter = count_screen_draws()
  request_redraw(); next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "the next request draws")
end)

-- A page draw that fails still finishes the frame: the header of the page
-- that is shown, "draw error" on the hint row, and screen.update(), so the
-- keys never act on a page the screen does not show (#424)
test("a page draw that fails still shows its page: the title, draw error on the hint row, an update (#424)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.UI_PAGES
  show_page("FX")
  next_frame(context)
  local lfo = S.registry.pages[pages.index.LFO]
  local real_draw = lfo.draw
  lfo.draw = function()
    screen.move(0, 30); screen.text("half drawn")
    error("lfo draw failed")
  end
  local updates = 0
  local real_update = context.screen.update
  context.screen.update = function() updates = updates + 1 end
  context.printed = {}
  enc(1, 1)  -- FX to LFO
  context.clock.run_for(1)
  assert_equal(S.ui_page, pages.index.LFO, "the keys act on LFO")
  assert_true(updates >= 1, "the frame is pushed to the screen")
  local title
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 8 then title = entry.text end
  end
  assert_equal(title, "LFO", "the header names the page that is shown")
  assert_equal(h.hint_text(context), "draw error", "the hint row says the draw failed")
  assert_true(not screen_shows(context, "half drawn"), "the half-drawn body is cleared")
  h.assert_screen_layout(context, "LFO after a failed draw")
  assert_equal(lines_printed(context, "lfo draw failed"), 1, "the error prints once")
  assert_true(context.printed[1]:find("stack traceback", 1, true) ~= nil, "with its traceback")
  -- the draw back, the page draws as before
  lfo.draw = real_draw
  request_redraw(); next_frame(context)
  context.screen.update = real_update
  assert_true(h.hint_text(context) ~= "draw error", "a good draw shows the page's hints again")
end)

-- A page whose hints() fails gives the same frame as a failing draw: the
-- page's title, "draw error" on the hint row, an update (#424)
test("a page whose hints() fails shows the draw error frame, and later redraws work (#424)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.UI_PAGES
  show_page("FX")
  next_frame(context)
  local fx = S.registry.pages[pages.index.FX]
  local real_hints = fx.hints
  fx.hints = function() error("fx hints failed") end
  local updates = 0
  local real_update = context.screen.update
  context.screen.update = function() updates = updates + 1 end
  context.printed = {}
  request_redraw(); next_frame(context)
  assert_equal(updates, 1, "the frame is pushed to the screen")
  local title
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 8 then title = entry.text end
  end
  assert_equal(title, "FX", "the header names the page that is shown")
  assert_equal(h.hint_text(context), "draw error", "the hint row says the draw failed")
  assert_equal(lines_printed(context, "fx hints failed"), 1, "the error prints once")
  h.assert_screen_layout(context, "FX after failed hints")
  fx.hints = real_hints
  request_redraw(); next_frame(context)
  context.screen.update = real_update
  assert_equal(updates, 2, "the next redraw is pushed too")
  assert_equal(h.hint_text(context), real_hints(false), "and shows the page's hints again")
end)

-- The menu watch's wrapper (lib/ui/menu_watch.lua) never lets a failure
-- stop the menu opening or the close hooks running (#425)
test("the menu opening forgets held keys even with the forget_held_keys global gone (#425)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  key(2, 1); key(1, 1)
  local real_forget = forget_held_keys
  forget_held_keys = nil
  local opened, open_error = pcall(_menu.set_mode, true)
  forget_held_keys = real_forget
  assert_true(opened, "the menu opens without raising: " .. tostring(open_error))
  assert_equal(_menu.mode, true, "the menu is open")
  assert_true(not S.alt_held, "ALT is forgotten")
  assert_true(next(S.key_press_page) == nil, "and so is the held K2")
  _menu.set_mode(false)
end)

test("a failing ALT-release hook does not stop the menu opening (#425)", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  S.register_alt_release(function() error("alt release boom") end)
  key(1, 1)
  context.printed = {}
  local opened, open_error = pcall(_menu.set_mode, true)
  assert_true(opened, "the menu opens without raising: " .. tostring(open_error))
  assert_equal(_menu.mode, true, "the menu is open")
  assert_true(not S.alt_held, "ALT is forgotten")
  assert_equal(lines_printed(context, "alt release boom"), 1, "the failure prints one line")
  _menu.set_mode(false)
end)

test("a set_mode(false) that raises still runs the menu-close hooks, then raises (#425)", function()
  local closes, fail_close = 0, false
  local context = load_strata({ before_init = function()
    local_value("S").register_menu_close(function() closes = closes + 1 end)
    -- norns' set_mode(false) ends with the script's redraw(): one that raises
    local norns_set_mode = _menu.set_mode
    _menu.set_mode = function(mode)
      norns_set_mode(mode)
      if mode == false and fail_close then error("redraw failed as the menu closed") end
    end
  end })
  finish_startup(context)
  _menu.set_mode(true)
  fail_close = true
  local closed, close_error = pcall(_menu.set_mode, false)
  fail_close = false
  assert_true(not closed, "norns' error still reaches its caller")
  assert_true(tostring(close_error):find("redraw failed as the menu closed", 1, true) ~= nil,
    "the error is norns' own: " .. tostring(close_error))
  assert_equal(_menu.mode, false, "the menu is closed")
  assert_equal(closes, 1, "the close hooks ran")
end)

-- norns can route keys, encoders and redraw() to the script before init
-- (a K1 tap while the engine loads): they do nothing until init's first
-- start step sets S.started (#426)
test("redraw, enc and key before init raise nothing and change nothing (#426)", function()
  local failures, drawn = {}, nil
  load_strata({ before_init = function(context)
    local calls = {
      { "redraw()", function() redraw() end },
      { "enc(1, 1)", function() enc(1, 1) end },
      { "enc(2, 1)", function() enc(2, 1) end },
      { "enc(3, 1)", function() enc(3, 1) end },
      { "key(1, 1)", function() key(1, 1) end },
      { "key(3, 1)", function() key(3, 1) end },
      { "key(3, 0)", function() key(3, 0) end },
    }
    for _, call in ipairs(calls) do
      local ok, err = pcall(call[2])
      if not ok then table.insert(failures, call[1] .. ": " .. tostring(err)) end
    end
    drawn = #context.screen.texts
  end })
  local S = local_value("S")
  assert_equal(table.concat(failures, "; "), "", "nothing raised before init")
  assert_equal(drawn, 0, "redraw() drew nothing before init")
  assert_equal(S.selected_voice, 1, "E2 before init selected no voice")
  assert_equal(S.ui_page, 1, "E1 before init changed no page")
  assert_true(not S.alt_held, "K1 before init held no ALT")
  assert_true(next(S.key_press_page) == nil, "no key is held")
  assert_true(S.started, "init's first start step sets S.started")
  enc(2, 1)
  assert_equal(S.selected_voice, 2, "after init E2 selects a voice")
end)

-- fit_text cuts a character at a time and stops when a pass removed
-- nothing, so a text it cannot shorten never loops (#514)
test("fit_text stops when a pass removes nothing (#514)", function()
  local context = load_strata()
  local fit_text = local_value("S").lib.ui_text.fit_text
  local real_extents = context.screen.text_extents
  local measures = 0
  context.screen.text_extents = function()
    measures = measures + 1
    if measures > 100 then error("fit_text kept measuring") end
    return 1000, 8  -- never fits
  end
  local bytes_cut, only_continuation = pcall(fit_text, "\128\129\130", 10)
  local bytes_measures = measures
  measures = 0
  local mixed_cut, mixed = pcall(fit_text, "\128\129ab", 10)
  context.screen.text_extents = real_extents
  assert_true(bytes_cut, "continuation bytes only: " .. tostring(only_continuation))
  assert_equal(only_continuation, "\128\129\130", "a text it cannot shorten comes back as it is")
  assert_true(bytes_measures <= 2, "measured " .. bytes_measures .. " times")
  assert_true(mixed_cut, "continuation bytes, then characters: " .. tostring(mixed))
  assert_equal(mixed, "\128\129", "the characters come off, then it stops")
  assert_equal(fit_text("abcdef", 10), "ab", "a text that can fit is cut to fit, as before")
end)

-- alt-and-keys.md's list of the menu-close hooks names as many as are
-- registered (#428)
test("the alt-and-keys notes name every menu-close hook (#428)", function()
  load_strata()
  local S = local_value("S")
  local file = assert(io.open(h.repo_root .. "/docs/notes/lua/ui/alt-and-keys.md"))
  local text = file:read("*a"); file:close()
  local named
  for line in text:gmatch("[^\n]+") do
    local rest = line:match("The hooks today(.*)$")
    if rest then named = select(2, rest:gsub("`S%.lib%.[%w_]+%.[%w_]+`", "")) end
  end
  assert_true(named ~= nil, "the notes list the hooks")
  assert_equal(named, #S.registry.menu_close, "every registered hook is named")
end)

test("a draw that keeps failing prints its error once, until the error changes (#49)", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  next_frame(context)
  local real_redraw, real_arc_redraw = redraw, arc_redraw
  local screen_message = "screen draw failed"
  redraw = function() error(screen_message) end
  arc_redraw = function() error("arc draw failed") end
  local function failures_printed(text)
    local count = 0
    for _, line in ipairs(context.printed) do
      if line:find(text, 1, true) then count = count + 1 end
    end
    return count
  end
  context.printed = {}
  for _ = 1, 15 do  -- a second of frames, each asked for
    request_redraw()
    next_frame(context)
  end
  assert_equal(failures_printed("screen draw failed"), 1, "a persistent screen error prints once")
  assert_equal(failures_printed("arc draw failed"), 1, "a persistent arc error prints once")
  screen_message = "another screen failure"
  request_redraw(); next_frame(context)
  request_redraw(); next_frame(context)
  assert_equal(failures_printed("another screen failure"), 1, "a new error prints, once")
  assert_equal(failures_printed("arc draw failed"), 1, "the arc's unchanged error stays quiet")
  -- after a good frame the same error is news again
  redraw = real_redraw
  request_redraw(); next_frame(context)
  redraw = function() error(screen_message) end
  request_redraw(); next_frame(context)
  assert_equal(failures_printed("another screen failure"), 2, "the error after a good frame prints")
  -- a non-string error is a new table on every frame: keyed by its message
  -- field, or by its type when it has none, it still prints once
  context.printed = {}
  redraw = function() error({ message = "table draw failure" }) end
  for _ = 1, 15 do request_redraw(); next_frame(context) end
  assert_equal(failures_printed("frame draw failed"), 1, "a table error with a message prints once")
  assert_equal(failures_printed("table draw failure"), 1, "and shows its message")
  redraw = function() error({}) end
  for _ = 1, 15 do request_redraw(); next_frame(context) end
  assert_equal(failures_printed("frame draw failed"), 2, "a table error without one prints once too")
  redraw, arc_redraw = real_redraw, real_arc_redraw
end)

test("displayed changes from every source reach the screen and arc on the next frame (#11)", function()
  local context = load_strata()
  local arc_hardware = context.arc.plug(1)
  local grid_device = context.grid.plug(1, 16, 16)
  context.midi.plug(1, "keys")
  local voices = local_value("voices")
  show_page("MAIN")

  assert_drawn_on_next_frame(context, arc_hardware, "the startup clock starting voice 2", function()
    context.clock.advance_until(STARTUP.clock)
  end)
  assert_true(voices[2].active, "the startup clock started voice 2")
  assert_drawn_on_next_frame(context, arc_hardware, "MIDI note", function()
    context.midi.send(1, { type = "note_on", ch = 1, note = 69, vel = 100 })
  end)
  assert_true(screen_shows(context, "440 Hz"), "MAIN shows the note's frequency")
  -- nothing shows the bend: a wheel's stream draws nothing (#49)
  next_frame(context)
  local bend_counter = count_screen_draws()
  local bend_arc_refreshes = arc_hardware.refresh_count
  context.midi.send(1, { type = "pitchbend", ch = 1, val = 12000 })
  next_frame(context)
  bend_counter.restore()
  assert_equal(bend_counter.screen, 0, "MIDI pitchbend draws no screen")
  assert_equal(arc_hardware.refresh_count, bend_arc_refreshes, "nor the arc")
  assert_drawn_on_next_frame(context, arc_hardware, "MIDI note on a stopped voice", function()
    context.midi.send(1, { type = "note_on", ch = 4, note = 40, vel = 100 })
  end)
  assert_true(voices[4].active, "the note started voice 4")
  params:set("midi_note_off", 2)   -- voice off
  assert_drawn_on_next_frame(context, arc_hardware, "MIDI note off stopping a voice", function()
    context.midi.send(1, { type = "note_off", ch = 4, note = 40, vel = 0 })
  end)
  assert_true(not voices[4].active, "the note off stopped voice 4")

  params:set("mutation_probability", 1)
  assert_drawn_on_next_frame(context, arc_hardware, "gentle_mutate", gentle_mutate)

  -- K3 on MAIN and the arc button: test/unit/pages_main_test.lua. toggle_lock's
  -- callers (keys, arc, grid) ask for redraws too: call it directly
  assert_drawn_on_next_frame(context, arc_hardware, "toggle_lock", function() toggle_lock(1) end)
  assert_true(local_value("frozen")[1], "toggle_lock locked voice 1"); toggle_lock(1)
  assert_drawn_on_next_frame(context, arc_hardware, "grid voice button", function()
    context.grid.press(1, 13, 14, 1); context.grid.press(1, 13, 14, 0)
  end)
  assert_true(voices[5].active, "the grid started voice 5")
  assert_drawn_on_next_frame(context, arc_hardware, "arc turn", function() context.arc.turn(1, 2, 8) end)
  assert_drawn_on_next_frame(context, arc_hardware, "E3", function() enc(3, 1) end)
  assert_drawn_on_next_frame(context, arc_hardware, "E1 page change", function() enc(1, 1) end)
  assert_true(screen_shows(context, PAGE_TITLES[2]), "E1 moved to the next page")

  -- the FX, LFO, BUFFER and SETUP parts are in each page's unit file
  -- ("... reach the screen and arc on the next frame (#11)")
end)

test("many arc turns and encoder steps within one frame draw the screen and the arc once (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("MAIN")
  next_frame(context)
  local counter = count_screen_draws()
  local arc_refreshes = arc_hardware.refresh_count
  for _ = 1, 50 do
    for ring = 1, 4 do context.arc.turn(1, ring, 3) end
    enc(3, 1)
  end
  assert_equal(counter.screen, 0, "no draws between frames")
  assert_equal(arc_hardware.refresh_count, arc_refreshes, "no arc refreshes between frames")
  next_frame(context)
  assert_equal(counter.screen, 1, "one screen draw for the whole burst")
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1, "one arc redraw for the whole burst")
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 1, "the next frame has nothing left to draw")
  assert_equal(arc_hardware.refresh_count, arc_refreshes + 1)
end)

test("the frame clock redraws a page while its animates() is true", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local record = S.registry.pages[S.ui_page]
  local animating = true
  record.animates = function() return animating end
  context.clock.run_for(0.2)
  local counter = count_screen_draws()
  context.clock.run_for(1)
  assert_equal(counter.screen, 15, "15 frames in 1 s draw it 15 times")
  animating = false
  counter.screen = 0
  context.clock.run_for(1)
  assert_equal(counter.screen, 0, "false draws nothing")
  counter.restore()
end)

test("LFO animates while an LFO runs and SEQ while the patterns play", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local pages = S.constants.UI_PAGES.index
  local function draws_in_a_second(page)
    S.lib.ui_keys.set_ui_page(page)
    context.clock.run_for(0.2)
    local counter = count_screen_draws()
    context.clock.run_for(1)
    counter.restore()
    return counter.screen
  end
  assert_equal(draws_in_a_second(pages.LFO), 0, "LFO with none running draws nothing (#423)")
  params:set("lfo_1", 2)
  assert_equal(draws_in_a_second(pages.LFO), 15, "LFO draws every frame while an LFO runs")
  params:set("lfo_1", 1)
  S.pattern_playing = false
  assert_equal(draws_in_a_second(pages.SEQ), 0, "SEQ stopped draws nothing")
  S.pattern_playing = true
  assert_equal(draws_in_a_second(pages.SEQ), 15, "SEQ playing draws every frame")
  S.pattern_playing = false
end)

end

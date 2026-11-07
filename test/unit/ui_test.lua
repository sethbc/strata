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

test("E1 selects pages; MAIN keeps its encoder and key mappings", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(local_value("ui_page"), 1)
  local density = params:get("master_density")
  enc(1, 1); assert_equal(local_value("ui_page"), 2)
  assert_equal(params:get("master_density"), density, "E1 no longer changes density")
  enc(1, 10); assert_equal(local_value("ui_page"), #PAGE_TITLES, "E1 stops at the last page")
  enc(1, -10); assert_equal(local_value("ui_page"), 1)
  enc(2, 1); assert_equal(local_value("selected_voice"), 2)
  local before = params:get(main_param_id(2)); enc(3, 1)
  assert_true(params:get(main_param_id(2)) ~= before, "E3 moves the main param on MAIN")
  key(3, 1); assert_true(local_value("frozen")[2], "K3 freezes a running voice on MAIN")
end)

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

test("every encoder, key and arc control is safe on every page; arc button only acts on MAIN", function()
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
    if page ~= 1 then
      local frozen = deep_copy(local_value("frozen"))
      local active = {}
      for voice_idx, voice in ipairs(local_value("voices")) do active[voice_idx] = voice.active end
      context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
      for voice_idx, voice in ipairs(local_value("voices")) do
        assert_equal(voice.active, active[voice_idx], "arc button leaves voices alone on " .. PAGE_TITLES[page])
        assert_equal(local_value("frozen")[voice_idx], frozen[voice_idx], "arc button leaves freeze alone on " .. PAGE_TITLES[page])
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

  assert_drawn_on_next_frame(context, arc_hardware, "K3 on MAIN", function() key(3, 1); key(3, 0) end)
  assert_true(screen_shows(context, "[FREEZE]"), "K3 froze voice 1")
  assert_drawn_on_next_frame(context, arc_hardware, "arc button", function()
    context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  end)
  assert_true(not screen_shows(context, "[FREEZE]"), "the arc button unfroze voice 1")
  -- its callers (keys, arc, grid) ask for redraws too: call it directly
  assert_drawn_on_next_frame(context, arc_hardware, "toggle_freeze", function() toggle_freeze(1) end)
  assert_true(screen_shows(context, "[FREEZE]"), "toggle_freeze froze voice 1"); toggle_freeze(1)
  assert_drawn_on_next_frame(context, arc_hardware, "grid voice button", function()
    context.grid.press(1, 13, 14, 1); context.grid.press(1, 13, 14, 0)
  end)
  assert_true(voices[5].active, "the grid started voice 5")
  assert_drawn_on_next_frame(context, arc_hardware, "arc turn", function() context.arc.turn(1, 2, 8) end)
  assert_drawn_on_next_frame(context, arc_hardware, "E3", function() enc(3, 1) end)
  assert_drawn_on_next_frame(context, arc_hardware, "E1 page change", function() enc(1, 1) end)
  assert_true(screen_shows(context, PAGE_TITLES[2]), "E1 moved to the next page")

  show_page("FX")
  assert_drawn_on_next_frame(context, arc_hardware, "params:set of an FX param", function()
    params:set("filter_freq", 1234)
  end)
  assert_true(screen_shows(context, "1234 Hz"), "FX shows the new filter freq")

  show_page("LFO")
  assert_drawn_on_next_frame(context, arc_hardware, "LFO page K3", function() key(3, 1); key(3, 0) end)
  assert_equal(params:string("lfo_1"), "on", "K3 started LFO 1")

  show_page("BUFFER")
  assert_drawn_on_next_frame(context, arc_hardware, "bufferState report", function()
    context.polls.fire("bufferState", 305)
  end)
  assert_true(screen_shows(context, "5.0s"), "BUFFER shows the reported seconds")
  -- voice 1 records into slot 1; no report comes, so the take settles empty
  params:set("v1_source", 2)
  record_buffer(1)
  assert_drawn_on_next_frame(context, arc_hardware, "recording timer end", function()
    wake_buffer_clock(context, 1)
  end)
  assert_true(screen_shows(context, "K2:load K3:... K2+3:save"), "BUFFER shows the take finishing")
  assert_drawn_on_next_frame(context, arc_hardware, "fallback settle", function()
    wake_buffer_clock(context, 1)
  end)
  assert_true(screen_shows(context, "K2:load K3:rec K2+3:save"), "BUFFER shows the take settled")
  assert_true(grid_device.refresh_count > 0, "the grid still redraws on its own")

  -- hot-plugged devices: SETUP shows them
  show_page("SETUP")
  context.midi.unplug(1)
  assert_drawn_on_next_frame(context, arc_hardware, "midi.add", function() context.midi.plug(1, "pads") end)
  assert_true(screen_shows(context, "midi 1: pads"), "SETUP shows the new MIDI device")
  assert_drawn_on_next_frame(context, arc_hardware, "grid.add", function() context.grid.plug(2, 8, 8) end)
  assert_true(screen_shows(context, "grid: 2 connected"), "SETUP shows the second grid")
  assert_drawn_on_next_frame(context, arc_hardware, "grid.remove", function() context.grid.unplug(2) end)
  assert_true(screen_shows(context, "grid: 1 connected"), "SETUP shows the grid gone")
  assert_drawn_on_next_frame(context, nil, "arc.remove", function() context.arc.unplug(1) end)
  assert_true(screen_shows(context, "arc: none"), "SETUP shows the arc gone")
  local new_arc, arc_before_frame
  assert_drawn_on_next_frame(context, nil, "arc.add", function()
    new_arc = context.arc.plug(1); arc_before_frame = new_arc.refresh_count
  end)
  assert_true(screen_shows(context, "arc: connected"), "SETUP shows the new arc")
  assert_equal(arc_before_frame, 0, "arc.add: the new arc waits for the frame")
  assert_equal(new_arc.refresh_count, 1, "arc.add: the next frame draws the new arc once")
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

test("a K2 released inside the norns menu is forgotten: K3 records again (fix round 1)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  local drift_metro = local_value("drift_metro")
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens the menu: the K2 release goes to the menu
  key(2, 1)
  context.menu.mode = true; drift_metro.event()   -- a 10 Hz tick while the menu is open
  context.menu.mode = false                       -- K1 again: back to the script
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save after K2 was released in the menu")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  assert_equal(context.fileselect.last, nil, "nothing opened the file selector")
  -- a save made with K2 held, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 still saves")
  context.menu.mode = true; drift_metro.event(); context.menu.mode = false
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector after the menu")
  -- ticks with the menu closed keep a held K2
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); drift_metro.event(); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2 still held across a tick with the menu closed")
  key(2, 0); assert_equal(context.fileselect.last, nil)
  assert_equal(norns.menu.status(), false, "stub norns.menu.status mirrors _menu.mode")
end)

test("opening the norns menu forgets held keys at once; cleanup restores _menu.set_mode", function()
  local stub_set_mode
  local context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  finish_startup(context); show_page("BUFFER")
  assert_true(_menu.set_mode ~= stub_set_mode, "init watches _menu.set_mode")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)
  context.clear_engine_calls(); context.fileselect.last = nil
  -- K2 down, then K1 opens and closes the menu between two 10 Hz ticks
  key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the wrapped set_mode still opens the menu")
  assert_equal(local_value("key_press_page")[2], nil, "the held K2 is forgotten as the menu opens")
  _menu.set_mode(false)
  tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 0, "K3 does not save")
  assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records")
  -- a K2+K3 save, then the menu: the next K2 tap opens the selector
  tap(3)  -- stop the recording
  context.polls.fire("bufferState", 202)  -- the engine reports the 2 s take
  key(2, 1); tap(3); assert_equal(#context.calls_named("saveBuffer"), 1)
  _menu.set_mode(true); _menu.set_mode(false)
  tap(2); assert_true(context.fileselect.last ~= nil, "a plain K2 opens the selector")
  -- closing the menu forgets nothing (only an opening does)
  key(2, 1); _menu.set_mode(false)
  assert_equal(local_value("key_press_page")[2], local_value("UI_PAGES").index.BUFFER, "set_mode(false) keeps a held key")
  key(2, 0)
  -- cleanup gives norns its own set_mode back
  cleanup()
  assert_equal(_menu.set_mode, stub_set_mode, "cleanup restores set_mode")
  -- something that wrapped set_mode after Strata keeps its wrapper; Strata's goes inert
  stub_set_mode = nil
  context = load_strata({ before_init = function() stub_set_mode = _menu.set_mode end })
  local strata_set_mode = _menu.set_mode
  local mod_set_mode = function(mode) strata_set_mode(mode) end
  _menu.set_mode = mod_set_mode
  cleanup()
  assert_equal(_menu.set_mode, mod_set_mode, "a later wrapper is left in place")
  show_page("BUFFER"); key(2, 1)
  _menu.set_mode(true)
  assert_equal(norns.menu.status(), true, "the inert wrapper still passes the call on")
  assert_equal(local_value("key_press_page")[2], local_value("UI_PAGES").index.BUFFER, "and no longer touches the script's keys")
  _menu.set_mode(false)
end)

test("key releases reach only the BUFFER page; other pages act once per press", function()
  local context = load_strata(); finish_startup(context)
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(2)
  show_page("MAIN")
  key(3, 1); assert_true(local_value("frozen")[2], "K3 press freezes on MAIN")
  key(3, 0); assert_true(local_value("frozen")[2], "K3 release does not unfreeze")
  show_page("FX")
  local mix = params:get("filter_mix")
  key(3, 1); key(3, 0)
  assert_true(params:get("filter_mix") ~= mix, "FX K3 press bypasses once, the release does not undo it")
  show_page("SETUP"); context.clear_engine_calls()
  local saved = 0
  local real_save = save_scenes_to_disk
  save_scenes_to_disk = function() saved = saved + 1 end
  key(3, 1); key(3, 0)
  save_scenes_to_disk = real_save
  assert_equal(saved, 1, "SETUP K3 saves once per press")
end)

end

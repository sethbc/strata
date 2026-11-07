-- test/unit/pages_test.lua
-- The screen pages: MAIN, FX, LFO, BUFFER (and its file selector) and
-- SETUP, their layout and keys (lib/pages/)
-- Run alone: lua test/run.lua pages

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value = h.load_strata, h.find_upvalue, h.local_value
local next_frame, finish_startup, text_span = h.next_frame, h.finish_startup, h.text_span
local PAGE_TITLES, HINT_ROW_Y, TEXT_HEIGHT = h.PAGE_TITLES, h.HINT_ROW_Y, h.TEXT_HEIGHT
local show_page, assert_screen_layout = h.show_page, h.assert_screen_layout
local count_screen_draws, tap = h.count_screen_draws, h.tap

test("MAIN shows [TRIG] for a voice in triggered grain mode", function()
  local context = load_strata(); finish_startup(context)
  local function trig_drawn()
    redraw()
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == "[TRIG]" then return entry end
    end
  end
  assert_true(not trig_drawn(), "no indicator in continuous mode")
  params:set("v1_grain_mode", 2)
  local entry = trig_drawn()
  assert_true(entry, "indicator in triggered mode")
  assert_equal(entry.y, 42, "on the main parameter label row")
end)

test("every page's header, hints and text stay apart and inside 128x64 (M7)", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  params:set("master_density", 2.0)
  capture_scene(8)
  recall_scene(8, 0)
  -- the widest SETUP page: four grids of every size and an arc
  context.grid.plug(1, 16, 16)
  context.grid.plug(2, 16, 8)
  context.grid.plug(3, 8, 16)
  context.grid.plug(4, 8, 8)
  context.arc.plug(1)
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    set_selected(voice_idx)
    if not voices[voice_idx].active then toggle_voice(voice_idx) end
    if not local_value("frozen")[voice_idx] then toggle_freeze(voice_idx) end
    params:set("v" .. voice_idx .. "_grain_mode", 2)  -- MAIN shows [TRIG]
    for page = 1, #PAGE_TITLES do
      show_page(page)
      assert_screen_layout(context, PAGE_TITLES[page] .. ", voice " .. voice_idx)
    end
  end
  -- UI.ScrollingList draws row i at y + 5 + (i - 1) * 11; its last row must
  -- end above the hint row
  local voice_list = local_value("voice_list")
  local last_row_y = voice_list.y + 5 + (voice_list.num_visible - 1) * 11
  assert_true(last_row_y <= HINT_ROW_Y - TEXT_HEIGHT,
    "voice list's last row (y " .. last_row_y .. ") clears the hint row")
end)

test("MAIN voice list fits its column for every voice, state and selection (#23)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local _, set_selected = find_upvalue("selected_voice")
  local states = { { active = false, frozen = false }, { active = false, frozen = true },
    { active = true, frozen = false }, { active = true, frozen = true } }
  local entries_by_state = {}
  for state_idx, state in ipairs(states) do
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= state.active then toggle_voice(voice_idx) end
      if (frozen[voice_idx] or false) ~= state.frozen then toggle_freeze(voice_idx) end
    end
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      update_voice_list()
      show_page("MAIN")
      local where = string.format("MAIN, voice %d, active %s, frozen %s", voice_idx,
        tostring(state.active), tostring(state.frozen))
      assert_screen_layout(context, where)
      -- the list draws its four rows; the selected voice's entry is bright
      local voice_list = local_value("voice_list")
      local rows_drawn, selected_entry = 0, nil
      for _, entry in ipairs(context.screen.texts) do
        local row = (entry.y - voice_list.y - 5) / 11
        if entry.x == voice_list.x and row >= 0 and row < voice_list.num_visible and row % 1 == 0 then
          rows_drawn = rows_drawn + 1
          if entry.level == 15 then selected_entry = entry.text end
        end
      end
      assert_equal(rows_drawn, voice_list.num_visible, "list rows drawn (" .. where .. ")")
      assert_equal(selected_entry, voice_list.entries[voice_idx], "selected entry bright (" .. where .. ")")
    end
    entries_by_state[state_idx] = local_value("voice_list").entries
  end
  for voice_idx = 1, 7 do
    local stopped, stopped_frozen = entries_by_state[1][voice_idx], entries_by_state[2][voice_idx]
    local running, running_frozen = entries_by_state[3][voice_idx], entries_by_state[4][voice_idx]
    assert_true(stopped ~= running, "running and stopped entries differ: " .. stopped)
    assert_true(not stopped:find("[F]", 1, true) and not running:find("[F]", 1, true), "[F] only when frozen")
    assert_true(stopped_frozen:find("[F]", 1, true) and running_frozen:find("[F]", 1, true),
      "frozen entries show [F]: " .. running_frozen)
    -- every entry is plain ASCII, so its width does not depend on how the
    -- norns font draws other glyphs
    for _, entry in ipairs({ stopped, stopped_frozen, running, running_frozen }) do
      assert_true(not entry:find("[\128-\255]"), "ASCII entry: " .. entry)
    end
  end
end)

test("every voice type's list name is at most 5 characters, as MAIN_PARAMS states (#49)", function()
  load_strata()
  local main_params = local_value("MAIN_PARAMS")
  local voices = local_value("voices")
  for voice_idx = 1, #voices do
    local voice_type = voices[voice_idx].name
    local list_name = main_params[voice_type].list_name
    assert_true(type(list_name) == "string" and #list_name >= 1, voice_type .. " has a list name")
    assert_true(#list_name <= 5, voice_type .. "'s list name '" .. list_name .. "' has at most 5 characters")
  end
end)

test("every page draws within 128x64 with a header and hint row", function()
  local context = load_strata(); finish_startup(context)
  for page = 1, #PAGE_TITLES do
    show_page(PAGE_TITLES[page])
    local texts = context.screen.texts
    assert_equal(texts[1].text, PAGE_TITLES[page], "page title")
    for _, entry in ipairs(texts) do
      local left, right = text_span(entry)
      assert_true(left >= 0 and right <= 128 and entry.y <= 64, "text inside screen on page " .. page)
    end
  end
end)

test("main_param_id and main_param_label name each voice's E3 and arc ring 2 param", function()
  local context = load_strata()
  local device = context.arc.plug(1)
  local expected = { resonator = "freq", fm = "index", folder = "fold", sub = "drift",
    pulse = "width", karplus = "decay", ring = "ratio" }
  local voices = local_value("voices")
  local _, set_selected = find_upvalue("selected_voice")
  for voice_idx = 1, 7 do
    local key_name = expected[voices[voice_idx].name]
    local param_id = "v" .. voice_idx .. "_" .. key_name
    assert_equal(main_param_id(voice_idx), param_id, "main param id of voice " .. voice_idx)
    assert_equal(main_param_label(voice_idx), key_name, "main param label of voice " .. voice_idx)
    -- arc ring 2 adjusts it and shows it across its controlspec range,
    -- following the warp (param_fraction, as the FX and BUFFER rings)
    set_selected(voice_idx)
    local min_value, max_value = param_range(param_id)
    params:set(param_id, min_value)
    context.arc.turn(1, 2, 100)  -- enough for one step of sub's fine-scaled drift
    next_frame(context)
    local value = params:get(param_id)
    assert_true(value > min_value, "arc ring 2 raises " .. param_id)
    assert_near(device.segments[2].to, param_fraction(param_id) * math.pi * 2, 1e-9, "ring 2 shows " .. param_id)
    -- MAIN shows the label and value in the right column
    redraw()
    local label_found = false
    for _, entry in ipairs(context.screen.texts) do
      if entry.x == 65 and entry.y == 42 and entry.text == key_name then label_found = true end
    end
    assert_true(label_found, "MAIN shows the " .. key_name .. " label")
  end
  -- an exp main param: the resonator's freq at the sweep's midpoint (200 Hz
  -- on 20-2000) is drawn at half a turn, not at its linear 9 %
  set_selected(1)
  params:set("v1_freq", 20)
  for _ = 1, 256 do context.arc.turn(1, 2, 1) end
  next_frame(context)
  assert_near(params:get("v1_freq"), 200, 1e-6, "256 ticks reach the exp midpoint")
  assert_near(device.segments[2].to, math.pi, 1e-6, "ring 2 draws the exp midpoint at half a turn")
end)

test("SETUP page shows grids, arc and scenes; K3 saves scenes to disk", function()
  local context = load_strata()
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  show_page("SETUP")
  assert_true(screen_has("grid: 0 connected"), "no grids")
  assert_true(screen_has("arc: none"), "no arc")
  assert_true(screen_has("scenes: 0/8 saved"), "no scenes")
  context.grid.plug(1, 16, 16)
  context.grid.plug(3, 8, 8)
  context.arc.plug(1)
  capture_scene(3)
  redraw()
  assert_true(screen_has("grid: 2 connected"), "two grids")
  assert_true(screen_has("16x16 8x8"), "grid sizes in port order")
  assert_true(screen_has("arc: connected"), "arc connected")
  assert_true(screen_has("scenes: 1/8 saved"), "one scene")
  context.arc.unplug(1)
  context.grid.unplug(3)
  next_frame(context)
  assert_true(screen_has("arc: none"), "unplugging the arc redraws SETUP on the next frame")
  assert_true(screen_has("grid: 1 connected"), "unplugging a grid redraws SETUP on the next frame")

  local scene_file = context.data_dir .. "strata/scenes.data"
  assert_true(not util.file_exists(scene_file), "no scenes file yet")
  key(3, 1)
  assert_true(util.file_exists(scene_file), "K3 on SETUP saves scenes")
end)

test("FX page: E2 selects a row, E3 adjusts it, K3 bypasses the filter", function()
  local context = load_strata(); show_page("FX")
  params:set("filter_mix", 0.8); key(3, 1); assert_equal(params:get("filter_mix"), 0)
  key(3, 1); assert_near(params:get("filter_mix"), 0.8, 1e-6)
  enc(2, 3); local before = params:get("filter_freq"); enc(3, 2)
  assert_true(params:get("filter_freq") > before, "row 4 is filter freq")
  -- K3 from a bypassed default turns the filter fully on
  context = load_strata(); show_page("FX")
  key(3, 1); assert_equal(params:get("filter_mix"), 1, "first K3 turns the filter on")
  local function hint_text()
    for _, entry in ipairs(context.screen.texts) do
      if entry.y == 62 then return entry.text end
    end
  end
  redraw(); assert_equal(hint_text(), "K3:filter bypass")
  key(3, 1); redraw(); assert_equal(hint_text(), "K3:filter on")
end)

test("FX page K3 restores the last non-zero filter mix however it was set", function()
  load_strata(); show_page("FX")
  enc(2, 5)                                    -- row 6: filter mix
  enc(3, 50); assert_near(params:get("filter_mix"), 0.5, 1e-6, "E3 sets the mix to 0.5")
  enc(3, -50); assert_equal(params:get("filter_mix"), 0, "E3 brings it to 0")
  key(3, 1); assert_near(params:get("filter_mix"), 0.5, 1e-6, "K3 restores the mix E3 last set")
  params:set("filter_mix", 0.3); params:set("filter_mix", 0)  -- PARAMS menu, scene recall, ...
  key(3, 1); assert_near(params:get("filter_mix"), 0.3, 1e-6, "K3 restores a mix set through params")
end)

test("FX page rows stay apart and inside 128x64 at every row and value", function()
  local context = load_strata()
  params:set("mutation_enabled", 1)
  capture_scene(8); recall_scene(8, 0)
  show_page("FX")
  local rows = local_value("FX_PAGE").rows
  assert_equal(#rows, 12, "density, drift, 4 filter, 3 delay, 3 reverb rows")
  local function screen_has(text)
    for _, entry in ipairs(context.screen.texts) do
      if entry.text == text then return true end
    end
    return false
  end
  for _, extreme in ipairs({ "max", "min" }) do
    for _, row in ipairs(rows) do
      local min_value, max_value = param_range(row.param_id)
      if row.param_id == "filter_type" then min_value, max_value = 2, 3 end  -- highpass, bandpass
      params:set(row.param_id, extreme == "max" and max_value or min_value)
    end
    enc(2, -100)
    for row = 1, #rows do
      assert_equal(local_value("fx_row"), row, "E2 steps one row")
      redraw()
      assert_screen_layout(context, "FX row " .. row .. ", " .. extreme)
      assert_true(screen_has(rows[row].label), "selected row " .. rows[row].label .. " is visible")
      enc(2, 1)
    end
    assert_equal(local_value("fx_row"), #rows, "E2 stops at the last row")
  end
end)

test("buffer-sourced voices: E3, arc ring 2 and MAIN use buf_pos", function()
  local context = load_strata(); finish_startup(context)
  local device = context.arc.plug(1)
  params:set("v1_source", 3)
  params:set("v1_buf_pos", 0.5)
  local freq = params:get("v1_freq")
  enc(3, 2)
  assert_near(params:get("v1_buf_pos"), 0.52, 1e-6, "E3 moves buf_pos")
  assert_equal(params:get("v1_freq"), freq, "E3 leaves the synth freq alone")
  context.arc.turn(1, 2, 10); next_frame(context)
  assert_true(params:get("v1_buf_pos") > 0.52, "arc ring 2 moves buf_pos")
  assert_equal(params:get("v1_freq"), freq, "arc ring 2 leaves the synth freq alone")
  assert_near(device.segments[2].to, params:get("v1_buf_pos") * math.pi * 2, 1e-9, "ring 2 shows buf_pos")
  redraw()
  local label, value
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 65 and entry.y == 42 then label = entry.text end
    if entry.x == 65 and entry.y == 50 then value = entry.text end
  end
  assert_equal(label, "pos", "MAIN label")
  assert_equal(value, string.format("%.2f", params:get("v1_buf_pos")), "MAIN value")
end)

test("MAIN layout holds for buffer- and input-sourced voices", function()
  local context = load_strata(); finish_startup(context)
  local _, set_selected = find_upvalue("selected_voice")
  for _, source in ipairs({ 9, 10 }) do
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      params:set("v" .. voice_idx .. "_source", source)
      params:set("v" .. voice_idx .. "_buf_pos", 1)
      params:set("v" .. voice_idx .. "_grain_mode", 2)
      if not local_value("frozen")[voice_idx] then toggle_freeze(voice_idx) end
      show_page("MAIN")
      assert_screen_layout(context, "MAIN, voice " .. voice_idx .. " source " .. source)
    end
  end
end)

local texts_on_row, hint_text = h.texts_on_row, h.hint_text

test("BUFFER page: E3 cycles source, K3 records into the voice's slot, K2 opens the file selector", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  enc(3, 2); assert_equal(params:get("v1_source"), 3)
  key(3, 1); assert_equal(context.calls_named("recordBuffer")[1].args[1], 1)
  key(3, 0)
  -- K2 acts on release (a 3.0 review fix), so the K2 press is a press and release
  tap(2); assert_true(context.fileselect.last ~= nil, "fileselect opened")
  assert_equal(context.fileselect.last.folder, _path.audio, "file selector starts in the audio folder")
  context.fileselect.last.callback("/tmp/b.wav"); assert_equal(params:get("buf2_file"), "/tmp/b.wav")
  params:set("v1_source", 1); context.clear_engine_calls(); context.fileselect.last = nil
  tap(3); tap(2)
  assert_equal(#context.calls_named("recordBuffer"), 0, "K3 does nothing for a synth voice")
  assert_equal(context.fileselect.last, nil, "K2 does nothing for a synth voice")
  redraw(); for _, entry in ipairs(context.screen.texts) do local l, r = text_span(entry); assert_true(r <= 128) end
  -- E2 selects the voice (shared with MAIN); a canceled selection loads nothing
  enc(2, 3); assert_equal(local_value("selected_voice"), 4)
  params:set("v4_source", 7); tap(2); context.clear_engine_calls()
  context.fileselect.last.callback("cancel")
  assert_equal(#context.calls_named("loadBuffer"), 0, "cancel loads nothing")
  assert_equal(voice_buffer_slot(4), 6); assert_equal(voice_buffer_slot(1), nil)
  params:set("v1_source", 10); assert_equal(voice_buffer_slot(1), nil, "input has no buffer slot")
end)

test("the BUFFER page caches each slot's cut name (M3)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local measured = 0
  local text_extents = screen.text_extents
  screen.text_extents = function(text) measured = measured + 1; return text_extents(text) end
  -- the loads redraw the page on the next frame (and measure the new names)
  for slot = 1, 8 do load_buffer(slot, "/tmp/a very long sample name number " .. slot .. ".wav") end
  next_frame(context)
  assert_true(measured > 0, "a new name is measured")
  measured = 0
  redraw(); redraw()
  screen.text_extents = text_extents
  assert_equal(measured, 0, "later draws reuse the cut names")
  local names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_true(names[14] ~= nil and #names[14] < 20, "the cached name is the cut one")
  load_buffer(1, "/tmp/b.wav"); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "b", "a new name is cut and shown")
  clear_buffer(1); redraw()
  names = {}
  for _, entry in ipairs(context.screen.texts) do if entry.x == 71 then names[entry.y] = entry.text end end
  assert_equal(names[14], "empty", "a cleared slot shows empty")
end)

test("BUFFER page: K2+K3 saves, K2 release then does not open the selector", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- the engine reports buffer 3's audio
  context.clear_engine_calls(); context.fileselect.last = nil
  key(2, 1); tap(3)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K3 with K2 held saves")
  assert_equal(context.calls_named("saveBuffer")[1].args[1], 2, "the voice's buffer")
  assert_equal(#context.calls_named("recordBuffer"), 0, "and does not record")
  tap(3); assert_equal(#context.calls_named("saveBuffer"), 2, "each K3 while K2 is held saves")
  key(2, 0); assert_equal(context.fileselect.last, nil, "K2 release after a save opens nothing")
  -- the next plain K2 opens the selector again, and a plain K3 records
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 alone opens the selector")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 alone records")
  tap(3); assert_equal(#context.calls_named("stopRecord"), 1, "K3 again stops early")
  context.polls.fire("bufferState", 205)  -- the engine reports the stopped take
  -- a K2 held across a page change is released elsewhere: no selector, and
  -- back on BUFFER K3 records
  context.fileselect.last = nil; context.clear_engine_calls()
  key(2, 1); show_page("MAIN"); key(2, 0); show_page("BUFFER")
  assert_equal(context.fileselect.last, nil, "K2 released on another page opens nothing")
  tap(3); assert_equal(#context.calls_named("recordBuffer"), 1, "K3 records once K2 is up")
  assert_equal(#context.calls_named("saveBuffer"), 0)
end)

test("BUFFER page K2+K3 confirms the save in the hint row for 1.5 s", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4); load_buffer(3, "/tmp/take.wav")
  context.polls.fire("bufferState", 204)  -- buffer 3 holds 4 s
  context.set_time(100)
  key(2, 1); tap(3); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "K2+K3 saves")
  assert_equal(hint_text(context), "saved buf 3", "the hint row confirms the save")
  assert_screen_layout(context, "BUFFER with the save confirmation")
  key(2, 0); next_frame(context); assert_equal(hint_text(context), "saved buf 3", "K2's release leaves it")
  context.set_time(101.4); redraw()
  assert_equal(hint_text(context), "saved buf 3", "still shown before 1.5 s")
  context.set_time(101.5); redraw()
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the normal hint after 1.5 s")
  -- an empty buffer: nothing saved, the hint says so
  context.polls.fire("bufferState", 200)  -- buffer 3 reports 0 s
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "an empty buffer is not saved")
  assert_equal(hint_text(context), "buf 3 empty", "the hint says the buffer is empty")
  assert_screen_layout(context, "BUFFER with the empty-buffer flash")
  -- one clock ends the flash: it sleeps 1.5 s, clears the flash (even if it
  -- woke a little early) and asks for a redraw
  local page = local_value("BUFFER_PAGE")
  local flash_clock = page.flash_clock
  assert_true(flash_clock ~= nil, "the flash has a clock")
  local flash_sleep
  for _, entry in ipairs(context.clock.sleep_log) do
    if entry.id == flash_clock then flash_sleep = entry.amount end
  end
  assert_near(flash_sleep, 1.5, 1e-9, "it sleeps 1.5 s")
  key(2, 1); tap(3); key(2, 0)   -- a second flash replaces the first one's clock
  assert_equal(context.clock.threads[flash_clock], nil, "the earlier clock is canceled")
  flash_clock = page.flash_clock
  context.clock.advance_until(flash_clock)        -- the flash clock wakes 1.5 s later
  assert_equal(context.clock.threads[flash_clock], nil, "the clock ends after one wake")
  assert_equal(page.flash_clock, nil)
  next_frame(context)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save", "the next frame shows the normal hint")
  -- cleanup cancels a pending flash clock
  key(2, 1); tap(3); key(2, 0)
  flash_clock = page.flash_clock
  cleanup()
  assert_equal(context.clock.threads[flash_clock], nil, "cleanup cancels the flash clock")
  assert_equal(page.flash_clock, nil)
end)

test("BUFFER page K2+K3 on a recording or finishing buffer flashes busy and saves nothing", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4)
  local buffers = local_value("buffers")
  tap(3); assert_true(buffers[3].recording, "K3 records into buffer 3")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while recording")
  assert_equal(#context.calls_named("stopRecord"), 0, "K2+K3 does not stop the recording")
  assert_equal(hint_text(context), "buf 3 busy", "the hint says the buffer is busy")
  assert_screen_layout(context, "BUFFER with the busy flash while recording")
  -- stopped early: the take waits for the engine (finishing)
  tap(3); assert_true(buffers[3].finishing, "the stopped take is finishing")
  context.clear_engine_calls()
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 0, "nothing saved while finishing")
  assert_equal(hint_text(context), "buf 3 busy", "still busy while finishing")
  assert_screen_layout(context, "BUFFER with the busy flash while finishing")
  -- once the engine reports the take, K2+K3 saves it
  context.polls.fire("bufferState", 205)
  assert_true(not buffers[3].finishing, "the take settled")
  key(2, 1); tap(3); key(2, 0); next_frame(context)
  assert_equal(#context.calls_named("saveBuffer"), 1, "the settled take saves")
  assert_equal(hint_text(context), "saved buf 3")
end)

test("BUFFER K2's release forgets every held key as the file selector opens", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 4)
  local held_at_enter
  local stub_enter = context.fileselect.enter
  context.fileselect.enter = function(...)
    held_at_enter = {}
    for n, page in pairs(local_value("key_press_page")) do held_at_enter[n] = page end
    return stub_enter(...)
  end
  -- K3 goes down (it records), then K2 is pressed and released while K3 is
  -- still held: the selector opens and takes K3's release
  key(3, 1); key(2, 1); key(2, 0)
  assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  assert_true(held_at_enter ~= nil and next(held_at_enter) == nil, "no key is held when the selector opens")
  assert_equal(next(local_value("key_press_page")), nil, "and none afterward")
  assert_equal(local_value("buffer_saved_during_k2"), false, "the K2-save flag is clear")
end)

test("BUFFER K2 loads a file with no fileselect global: the script requires it (issue #10)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  assert_equal(rawget(_G, "fileselect"), nil, "norns has no fileselect global")
  params:set("v1_source", 2)  -- voice 1 reads buffer 1
  context.clear_engine_calls()
  tap(2); assert_true(context.fileselect.last ~= nil, "K2's release opens the selector")
  context.fileselect.close("/tmp/picked.wav")
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1, "the chosen file loads")
  assert_equal(loads[1].args[1], 0); assert_equal(loads[1].args[2], "/tmp/picked.wav")
end)

test("Strata's page never draws over the open file selector; redraws draw the selector (issue #10)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local draws = 0  -- Strata's page draws (the stub's fileselect.redraw draws nothing)
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  local selector = context.fileselect
  -- opening it on K2's release: fs.enter's redraw() (from norns.menu.init)
  -- and the frame after key() draw the selector, not the page
  key(2, 1); next_frame(context); draws = 0
  key(2, 0); assert_true(selector.last ~= nil, "K2's release opens the selector")
  next_frame(context)
  assert_equal(draws, 0, "the page does not draw over the selector as it opens")
  assert_equal(selector.redraws, 3, "menu.init's redraw, fs.enter's own and the next frame draw the selector")
  -- the norns menu opened and closed over it (K1 twice): set_mode(false)
  -- clears the screen and calls redraw(), which must show the selector again
  selector.redraws = 0
  _menu.set_mode(true); _menu.set_mode(false); redraw()
  assert_equal(selector.redraws, 1, "norns' redraw() as the menu closes draws the selector")
  assert_equal(draws, 0, "and not Strata's page")
  -- Strata's own redraws (a buffer report, page turns, a load) while it is
  -- open: the frame clock's redraw() draws the selector
  selector.redraws = 0
  context.polls.fire("bufferState", 305)
  enc(1, -1); enc(1, 1)
  load_buffer(5, "/tmp/other.wav")
  next_frame(context)
  assert_equal(draws, 0, "the page does not draw over the selector while it is open")
  assert_true(selector.redraws > 0, "they draw the selector instead")
  -- canceled: fs.exit's redraw() comes before the callback, which asks
  -- for one redraw
  context.clear_engine_calls()
  context.fileselect.close()
  assert_equal(draws, 0, "the page waits for the next frame")
  next_frame(context)
  assert_equal(draws, 1, "a cancel redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 0, "a cancel loads nothing")
  assert_equal(PAGE_TITLES[local_value("ui_page")], "BUFFER")
  redraw(); assert_equal(draws, 2, "the script draws again after a cancel")
  -- a chosen file: loads it, then one redraw. K2's tap opens the selector
  -- before the next frame, which then draws the selector, not the page
  tap(2); next_frame(context); assert_equal(draws, 2, "the page does not draw as the selector opens again")
  draws = 0
  context.fileselect.close("/tmp/chosen.wav")
  next_frame(context)
  assert_equal(draws, 1, "a chosen file redraws once")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and loads")
  redraw(); assert_equal(draws, 2, "the script draws again after a choice")
  screen.update = update
end)

test("a file selector that fails to open leaves the BUFFER page drawing (#49)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local stub_enter = context.fileselect.enter
  local script_key, script_enc = key, enc
  -- fails after it has routed its own handlers to play mode, as fs.enter
  -- would if its redraw raised: globals swapped, then norns.menu.init()
  context.fileselect.enter = function()
    key, enc = function() end, function() end
    norns.menu.init()
    error("no audio folder")
  end
  key(2, 1)
  local released, release_error = pcall(key, 2, 0)
  context.fileselect.enter = stub_enter
  assert_true(not released, "K2's release raises the selector's error")
  assert_true(tostring(release_error):find("no audio folder", 1, true), "the same error: " .. tostring(release_error))
  assert_equal(_menu.key, script_key, "play mode routes the keys to Strata again")
  assert_equal(norns.encoders.callback, script_enc, "and the encoders")
  assert_equal(key, script_key, "the key global is Strata's")
  assert_equal(enc, script_enc, "and the enc global")
  assert_equal(local_value("BUFFER_PAGE").file_selector_open, false, "the selector state is cleared")
  local draws = 0
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  next_frame(context)
  screen.update = update
  assert_equal(draws, 1, "the next frame draws the page, not a selector that never opened")
  tap(2); assert_true(context.fileselect.last ~= nil, "K2 opens the selector afterward")
  context.fileselect.close("/tmp/after.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "and its choice loads")
end)

test("a menu file selector opened over BUFFER K2's gives Strata its keys and page back as the menu closes (#49)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local page = local_value("BUFFER_PAGE")
  local selector = context.fileselect
  local script_key, script_enc = key, enc
  -- norns' fs.enter, from play mode, puts its own key and enc handlers in
  -- the globals before norns.menu.init() routes them (the stub does not):
  -- only fs.exit for this selector restores them
  local selector_key, selector_enc = function() end, function() end
  local function open_strata_selector()
    tap(2); assert_true(page.file_selector_open, "K2 opens the selector")
    key, enc = selector_key, selector_enc
    norns.menu.init()
    assert_equal(_menu.key, selector_key, "the selector has the keys")
  end
  local function assert_strata_routed(where)
    assert_equal(page.file_selector_open, false, where .. ": the superseded selector state is cleared")
    assert_equal(_menu.key, script_key, where .. ": play mode routes the keys to Strata")
    assert_equal(norns.encoders.callback, script_enc, where .. ": and the encoders")
    assert_equal(key, script_key, where .. ": the key global is Strata's")
    assert_equal(enc, script_enc, where .. ": and the enc global")
  end
  open_strata_selector()
  -- K1 opens and closes the menu over it: the selector is still Strata's
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(page.file_selector_open, "the menu alone leaves the selector open")
  assert_equal(_menu.key, selector_key, "and its keys with it")
  -- K1, PARAMS, a file param: norns has one selector, now the menu's (Strata's
  -- callback is gone); fs.exit gives the menu its handlers back, not Strata's
  _menu.set_mode(true)
  local picked
  selector.enter(_path.audio, function(path) picked = path end)
  selector.close("/tmp/param.wav")
  assert_equal(picked, "/tmp/param.wav", "the PARAMS selector's choice")
  _menu.set_mode(false)  -- K1 back to play mode
  assert_strata_routed("a chosen PARAMS file")
  local draws, selector_redraws = 0, selector.redraws
  local update = screen.update
  screen.update = function() draws = draws + 1; return update() end
  redraw()
  screen.update = update
  assert_equal(draws, 1, "redraw() draws the page again")
  assert_equal(selector.redraws, selector_redraws, "not the file list")
  -- the PARAMS selector canceled (K2 in it) instead of a choice
  open_strata_selector()
  _menu.set_mode(true)
  selector.enter(_path.audio, function(path) picked = path end)
  selector.close()
  assert_equal(picked, "cancel", "the PARAMS selector was canceled")
  _menu.set_mode(false)
  assert_strata_routed("a canceled PARAMS selector")
  -- the menu closed while the PARAMS selector is still open
  open_strata_selector()
  _menu.set_mode(true)
  selector.enter(_path.audio, function() end)
  _menu.set_mode(false)
  assert_strata_routed("a PARAMS selector left open")
  -- Strata's own selector still works
  context.clear_engine_calls()
  tap(2); selector.close("/tmp/b.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "K2's selector loads its choice")
  assert_equal(page.file_selector_open, false)
end)

test("the superseded-selector release acts only as the menu closes, and never breaks BUFFER K2 (#49)", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  params:set("v1_source", 2)
  local page = local_value("BUFFER_PAGE")
  local selector = context.fileselect
  -- play mode to play mode (norns.menu.init in fs.enter and fs.exit) is
  -- no menu closing: a callback that is not Strata's changes nothing then
  tap(2)
  local strata_callback = selector.callback
  selector.callback = function() end
  norns.menu.init()
  assert_true(page.file_selector_open, "a set_mode(false) from play mode releases nothing")
  selector.callback = strata_callback
  selector.close("/tmp/a.wav")
  assert_equal(page.file_selector_open, false, "the selector's own callback closes it")
  -- a norns whose fileselect keeps no `callback`: no release ever (the
  -- selector state may stay set, as before #49), and K2 still works
  local stub_enter = selector.enter
  selector.enter = function(...)
    stub_enter(...)
    selector.callback = nil
  end
  context.clear_engine_calls()
  tap(2); assert_true(page.file_selector_open, "K2 opens the selector")
  _menu.set_mode(true); _menu.set_mode(false)
  assert_true(page.file_selector_open, "no fileselect.callback: the menu closing releases nothing")
  selector.close("/tmp/b.wav")
  assert_equal(#context.calls_named("loadBuffer"), 1, "the choice loads")
  assert_equal(page.file_selector_open, false, "and the callback closes it")
  selector.enter = stub_enter
  -- an error in the release never stops the menu closing
  tap(2)
  key, enc = function() end, function() end
  _menu.set_mode(true)
  selector.enter(_path.audio, function() end)
  local real_request_redraw = request_redraw
  request_redraw = function() error("release failed") end
  context.printed = {}
  local closed = pcall(_menu.set_mode, false)
  request_redraw = real_request_redraw
  assert_true(closed, "set_mode(false) does not raise")
  assert_equal(norns.menu.status(), false, "the menu closed")
  assert_true(table.concat(context.printed, "\n"):find("release failed", 1, true), "the error is printed")
end)

test("BUFFER page draws the voice, its source and eight buffer rows", function()
  local context = load_strata(); finish_startup(context); show_page("BUFFER")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(6); params:set("v6_source", 3)   -- karplus on buf 2
  load_buffer(2, "/tmp/drone.wav"); context.polls.fire("bufferState", 116)
  load_buffer(5, "/tmp/x.wav"); context.polls.fire("bufferState", 402.5)
  params:set("record_duration", 2); record_buffer(7)
  redraw()
  local left_name, left_source
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 18 then left_name = entry.text end
    if entry.x == 0 and entry.y == 26 then left_source = entry.text end
  end
  assert_equal(left_name, "KARPLUS"); assert_equal(left_source, "src: buf 2")
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x >= 65 then
      rows[entry.y] = rows[entry.y] or {}
      table.insert(rows[entry.y], entry)
    end
  end
  local row_ys = {}
  for y in pairs(rows) do table.insert(row_ys, y) end
  table.sort(row_ys)
  assert_equal(#row_ys, 8, "eight buffer rows")
  assert_true(row_ys[1] > 8 and row_ys[8] < HINT_ROW_Y - TEXT_HEIGHT + 1, "rows between header and hints")
  local function row_text(slot)
    local parts = {}
    for _, entry in ipairs(texts_on_row(context, row_ys[slot])) do
      if entry.x >= 65 then table.insert(parts, entry.text) end
    end
    return table.concat(parts, " ")
  end
  local function row_level(slot)
    local level
    for _, entry in ipairs(rows[row_ys[slot]]) do
      assert_true(level == nil or level == entry.level, "one level per row")
      level = entry.level
    end
    return level
  end
  assert_equal(row_text(1), "1 empty 0.0s"); assert_equal(row_level(1), 2, "empty buffer dim")
  assert_equal(row_text(2), "2 drone 16.0s"); assert_equal(row_level(2), 15, "the voice's buffer bright")
  assert_equal(row_text(5), "5 x 2.5s"); assert_equal(row_level(5), 8, "loaded buffer")
  assert_equal(row_text(7), "7 empty REC", "REC while recording"); assert_equal(row_level(7), 8)
  assert_equal(hint_text(context), "K2:load K3:rec K2+3:save")
  -- the voice's buffer recording: the hint says K3 stops
  record_buffer(2); redraw()
  assert_equal(hint_text(context), "K2:load K3:stop K2+3:save")
  -- not a buffer: the hint says K2 and K3 do nothing
  params:set("v6_source", 1); redraw()
  assert_equal(hint_text(context), "K2:- K3:- E3:source")
  params:set("v6_source", 10); redraw()
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == 0 and entry.y == 26 then assert_equal(entry.text, "src: input") end
  end
end)

test("BUFFER page layout holds for every voice, source and buffer state", function()
  local context = load_strata(); finish_startup(context)
  params:set("mutation_enabled", 1); params:set("master_density", 2.0)
  capture_scene(8); recall_scene(8, 0)
  local _, set_selected = find_upvalue("selected_voice")
  local long_names = { "WWWWWWWWWWWWWWWWWWWW.wav", "a_very_long_field_recording_name.aiff", "MMMM", "x",
    "café_crème_très_longue.wav", "no_extension_but_long" }
  local function set_buffers(state)
    for slot = 1, 8 do
      if state == "empty" then clear_buffer(slot)
      elseif state == "loaded" then
        load_buffer(slot, "/tmp/" .. long_names[(slot - 1) % #long_names + 1])
        context.polls.fire("bufferState", (slot - 1) * 100 + 16)
      elseif state == "recording" then
        clear_buffer(slot); record_buffer(slot)
      end
    end
  end
  for _, state in ipairs({ "empty", "loaded", "recording" }) do
    set_buffers(state)
    for voice_idx = 1, 7 do
      set_selected(voice_idx)
      for source = 1, 10 do
        params:set("v" .. voice_idx .. "_source", source)
        show_page("BUFFER")
        assert_screen_layout(context, "BUFFER, " .. state .. ", voice " .. voice_idx .. " source " .. source)
      end
    end
  end
end)

test("LFO page: E2 selects, E3 depth in percent, K3 enables, K2 cycles destination", function()
  local context = load_strata(); finish_startup(context)
  show_page("LFO")
  enc(2, 1); assert_equal(local_value("selected_lfo"), 2)
  enc(2, 5); assert_equal(local_value("selected_lfo"), 3, "clamped to 3 LFOs")
  enc(2, -1)
  enc(3, 7); assert_equal(params:get("lfo_depth_2"), 7, "E3 steps depth by percent")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "on")
  key(3, 1); key(3, 0); assert_equal(params:string("lfo_2"), "off")
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 2)
  params:set("strata_lfo2_dest", #local_value("LFO_DESTINATIONS"))
  key(2, 1); key(2, 0); assert_equal(params:get("strata_lfo2_dest"), 1, "K2 wraps to none")
  -- MAIN is untouched by LFO page input
  assert_equal(local_value("selected_voice"), 1)
end)

test("the LFO page redraws on every frame while it is shown, with no clock of its own", function()
  local context = load_strata(); finish_startup(context)
  local baseline = context.clock.pending_count()
  show_page("LFO")
  assert_equal(context.clock.pending_count(), baseline, "no page clock: the frame clock draws it")
  next_frame(context)
  local counter = count_screen_draws()
  next_frame(context); next_frame(context)
  assert_equal(counter.screen, 2, "each frame redraws, so the dots move")
  show_page("BUFFER"); next_frame(context)
  counter.screen = 0
  next_frame(context)
  counter.restore()
  assert_equal(counter.screen, 0, "other pages draw only when asked")
end)

-- The LFO page's waveform, dot and labels for LFO n
local function lfo_row_drawing(context, n)
  local top = 16 + (n - 1) * 15
  local row = { lines = {}, rects = {}, texts = {} }
  for _, line in ipairs(context.screen.lines) do
    if line.y1 >= top and line.y1 <= top + 10 then table.insert(row.lines, line) end
  end
  for _, rect in ipairs(context.screen.rects) do
    if rect.y >= top - 1 and rect.y <= top + 10 then table.insert(row.rects, rect) end
  end
  for _, entry in ipairs(context.screen.texts) do
    if entry.y > top and entry.y <= top + 11 then table.insert(row.texts, entry.text) end
  end
  return row
end

test("LFO page rows: waveform, dot from the last raw value and elapsed period, labels; cleanup stops LFOs", function()
  local context = load_strata(); finish_startup(context)
  local lfos = local_value("lfos")
  context.set_time(100)
  params:set("strata_lfo1_dest", 4); params:set("lfo_depth_1", 50); params:set("lfo_1", 2)
  context.lfo.tick(lfos[1], 0.25)
  show_page("LFO")
  -- three rows, each labeled, and every string inside the screen
  for n = 1, 3 do
    local row = lfo_row_drawing(context, n)
    assert_true(table.concat(row.texts, " "):find("L" .. n, 1, true), "row " .. n .. " labeled L" .. n)
    assert_true(#row.lines >= 63, "row " .. n .. " draws its waveform")
  end
  for _, entry in ipairs(context.screen.texts) do
    local left, right = text_span(entry)
    assert_true(left >= 0 and right <= 128 and entry.y <= 64, "'" .. entry.text .. "' inside the screen")
  end
  -- every drawn shape stays inside its row, rows inside y 14-58
  for _, line in ipairs(context.screen.lines) do
    assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "line inside y 14-58")
    assert_true(line.x1 >= 12 and line.x2 <= 75, "waveform inside x 12-75")
  end
  local row = lfo_row_drawing(context, 1)
  assert_true(#row.lines >= 63, "64 px waveform ")
  assert_equal(#row.rects, 1, "one dot for a running LFO")
  -- reset to the floor (phase 0.75) at t 100, so at t 100 the dot is at 0.75
  local dot = row.rects[1]
  assert_near(dot.x + 1, 12 + 0.75 * 63, 0.51, "dot x from the phase since the reset")
  assert_near(dot.y + 1, 16 + 10 - 0.25 * 10, 0.51, "dot y from the last raw value")
  assert_true(table.concat(row.texts, " "):find("filt freq"), "destination label")
  assert_true(table.concat(row.texts, " "):find("on 50%%"), "state and depth")
  -- one second later at a 4 s period: a quarter cycle further, wrapped to 0
  context.set_time(101); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12, 0.51, "dot advanced and wrapped")
  -- a period change keeps the phase (like the library), then advances at the new rate
  params:set("lfo_free_1", 2)
  context.set_time(101.5); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.25 * 63, 0.51, "advances at the new period")
  -- the phase offset shifts the dot, the reset trigger restarts it
  params:set("lfo_phase_1", 50); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "phase offset")
  params:set("lfo_phase_1", 0); params:set("lfo_reset_1", 1); redraw()
  assert_near(lfo_row_drawing(context, 1).rects[1].x + 1, 12 + 0.75 * 63, 0.51, "reset to the floor")
  -- stopped LFOs draw no dot
  assert_equal(#lfo_row_drawing(context, 2).rects, 0, "no dot for a stopped LFO")
  assert_true(table.concat(lfo_row_drawing(context, 2).texts, " "):find("off 0%%"), "stopped LFO shows off")
  -- every shape and every destination label keeps the page apart and inside the screen
  for shape = 1, 6 do
    for n = 1, 3 do params:set("lfo_shape_" .. n, shape) end
    for _, dest in ipairs({ 1, 3, 12, 17, 68 }) do
      params:set("strata_lfo2_dest", dest); params:set("lfo_depth_2", 100); redraw()
      assert_screen_layout(context, "LFO shape " .. shape .. ", dest " .. dest)
      for _, line in ipairs(context.screen.lines) do
        assert_true(line.y1 >= 14 and line.y2 <= 58 and line.y2 >= 14 and line.y1 <= 58, "shape " .. shape .. " inside rows")
      end
    end
  end
  -- cleanup turns a running LFO off
  params:set("lfo_3", 2); cleanup(); assert_equal(params:get("lfo_3"), 1, "cleanup stops LFO 3")
end)

end

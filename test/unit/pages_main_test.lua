-- test/unit/pages_main_test.lua
-- The MAIN page (lib/pages/main.lua): the voice list, the details
-- column, E2/E3/K2/K3, the main parameter and its buffer and input forms
-- Run alone: lua test/run.lua pages_main

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, PAGE_TITLES, HINT_ROW_Y = h.finish_startup, h.text_span, h.PAGE_TITLES, h.HINT_ROW_Y
local TEXT_HEIGHT, show_page, assert_screen_layout, count_screen_draws = h.TEXT_HEIGHT, h.show_page, h.assert_screen_layout, h.count_screen_draws
local tap, wake_buffer_clock, deep_copy, screen_shows = h.tap, h.wake_buffer_clock, h.deep_copy, h.screen_shows
local assert_drawn_on_next_frame = h.assert_drawn_on_next_frame

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
      if (frozen[voice_idx] or false) ~= state.frozen then toggle_lock(voice_idx) end
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
    assert_true(not stopped:find("[L]", 1, true) and not running:find("[L]", 1, true), "[L] only when locked")
    assert_true(stopped_frozen:find("[L]", 1, true) and running_frozen:find("[L]", 1, true),
      "locked entries show [L]: " .. running_frozen)
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
      if not local_value("frozen")[voice_idx] then toggle_lock(voice_idx) end
      show_page("MAIN")
      assert_screen_layout(context, "MAIN, voice " .. voice_idx .. " source " .. source)
    end
  end
end)

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
  key(3, 1); assert_true(local_value("frozen")[2], "K3 locks a running voice on MAIN")
end)

test("MAIN K3 and the arc button reach the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("MAIN")
  assert_drawn_on_next_frame(context, arc_hardware, "K3 on MAIN", function() key(3, 1); key(3, 0) end)
  assert_true(screen_shows(context, "[LOCK]"), "K3 locked voice 1")
  assert_drawn_on_next_frame(context, arc_hardware, "arc button", function()
    context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  end)
  assert_true(not screen_shows(context, "[LOCK]"), "the arc button unlocked voice 1")
end)

test("MAIN acts once per K3 press; the release does nothing", function()
  local context = load_strata(); finish_startup(context)
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(2)
  show_page("MAIN")
  key(3, 1); assert_true(local_value("frozen")[2], "K3 press locks on MAIN")
  key(3, 0); assert_true(local_value("frozen")[2], "K3 release does not unlock")
end)

end

-- test/unit/pages_main_test.lua
-- The MAIN page (lib/pages/main.lua): the voice list, the details column
-- and its three fields, E2/E3/K2/K3, ALT+K2/ALT+K3, the hints, the arc
-- button, the main parameter and its buffer and input forms
-- Run alone: lua test/run.lua pages_main

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, find_upvalue, local_value, next_frame = h.load_strata, h.find_upvalue, h.local_value, h.next_frame
local finish_startup, text_span, show_page, assert_screen_layout = h.finish_startup, h.text_span, h.show_page, h.assert_screen_layout
local tap, screen_shows, hint_text, texts_on_row = h.tap, h.screen_shows, h.hint_text, h.texts_on_row
local assert_drawn_on_next_frame = h.assert_drawn_on_next_frame

-- MAIN's details column: the field rows (main param or grain size, then
-- grain size/density or density/pitch), the label column after the cursor
local FIELD_ROWS = { 34, 42, 50 }
local LABEL_X = 71

-- The drawn strings of the voice list's rows (x 0, between the header and
-- the hint row), top to bottom
local function list_rows(context)
  local voice_list = local_value("voice_list")
  local rows = {}
  for _, entry in ipairs(context.screen.texts) do
    if entry.x == voice_list.x and entry.y > 8 and entry.y < 62 then
      rows[(entry.y - voice_list.y - 5) / 11 + 1] = entry
    end
  end
  return rows
end

-- The label (at LABEL_X) and right-aligned value of field row `field` (1-3)
local function field_texts(context, field)
  local label, value, marker
  for _, entry in ipairs(texts_on_row(context, FIELD_ROWS[field])) do
    if entry.x == LABEL_X and entry.align == "left" then label = entry end
    if entry.x == 127 and entry.align == "right" then value = entry end
    if entry.text == ">" then marker = entry end
  end
  return label, value, marker
end

local function select_voice(voice_idx)
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(voice_idx)
  update_voice_list()
end

test("MAIN voice list entries read <n><+|-> <name> with [L]", function()
  local context = load_strata(); finish_startup(context)
  toggle_lock(3)
  local entries = local_value("voice_list").entries
  assert_equal(entries[1], "1+ reso", "voice 1 runs")
  assert_equal(entries[2], "2+ fm", "voice 2 runs")
  assert_equal(entries[3], "3- fold [L]", "voice 3 is stopped and locked")
  assert_equal(entries[7], "7- ring", "voice 7 is stopped")
  -- the widest entry ends left of the divider
  for voice_idx = 1, 7 do
    if not local_value("voices")[voice_idx].active then toggle_voice(voice_idx) end
    if not local_value("frozen")[voice_idx] then toggle_lock(voice_idx) end
  end
  entries = local_value("voice_list").entries
  assert_equal(entries[5], "5+ pulse [L]")
  for _, entry in ipairs(entries) do
    assert_true(h.text_width(entry) <= 60, "'" .. entry .. "' ends by x 60")
  end
end)

test("the voice list shows four voices and never scrolls past an end", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local entries = local_value("voice_list").entries
  for voice_idx = 1, 7 do
    select_voice(voice_idx)
    redraw()
    local rows = list_rows(context)
    for row = 1, 4 do
      assert_true(rows[row] ~= nil, "row " .. row .. " drawn (voice " .. voice_idx .. ")")
      assert_true(rows[row].text ~= "", "no blank row " .. row .. " (voice " .. voice_idx .. ")")
    end
    local selected_shown = false
    for row = 1, 4 do
      if rows[row].text == entries[voice_idx] then
        selected_shown = true
        assert_equal(rows[row].level, 15, "the selected voice is bright")
      end
    end
    assert_true(selected_shown, "the selected voice " .. voice_idx .. " is in view")
    if voice_idx == 1 then
      for row = 1, 4 do assert_equal(rows[row].text, entries[row], "selected 1: voices 1-4") end
    elseif voice_idx == 7 then
      for row = 1, 4 do assert_equal(rows[row].text, entries[row + 3], "selected 7: voices 4-7") end
    end
  end
end)

test("the voice list follows a selection made without update_voice_list", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local _, set_selected = find_upvalue("selected_voice")
  set_selected(7)
  redraw()
  local rows = list_rows(context)
  assert_equal(rows[4].text, local_value("voice_list").entries[7], "voice 7 on the last row")
  assert_equal(rows[4].level, 15, "and bright")
end)

test("MAIN details show name, source, state and three fields", function()
  local context = load_strata(); finish_startup(context)
  params:set("v1_mod_source_1", 3)  -- MAIN no longer shows crossmod sources
  show_page("MAIN")
  -- row y 18: the name (cut to fit before the source) and the source
  local name, source
  for _, entry in ipairs(texts_on_row(context, 18)) do
    if entry.x == 65 then name = entry.text end
    if entry.x == 127 and entry.align == "right" then source = entry.text end
  end
  assert_true(name and name ~= "" and ("RESONATOR"):sub(1, #name) == name, "the name: " .. tostring(name))
  assert_equal(source, "synth", "the source right-aligned at 127")
  -- the name is whole where it fits
  select_voice(2); redraw()
  assert_true(screen_shows(context, "FM"), "FM's name is whole")
  select_voice(3); redraw()
  assert_true(screen_shows(context, "FOLDER"), "FOLDER's name is whole")
  select_voice(1); redraw()
  -- row y 26: state, then [L] and [T]
  local row = texts_on_row(context, 26)
  local states = {}
  for _, entry in ipairs(row) do if entry.x >= 65 then states[#states + 1] = entry.text end end
  assert_equal(table.concat(states, " "), "ON", "running, unlocked, continuous")
  toggle_lock(1)
  params:set("v1_grain_mode", 2)
  redraw()
  states = {}
  for _, entry in ipairs(texts_on_row(context, 26)) do if entry.x >= 65 then states[#states + 1] = entry.text end end
  assert_equal(table.concat(states, " "), "ON [L] [T]", "locked and triggered")
  assert_true(not screen_shows(context, "[LOCK]") and not screen_shows(context, "[TRIG]"), "no long forms")
  -- rows y 34/42/50: freq, size, dens with their units
  local expected = {
    { "freq", string.format("%.0f Hz", params:get("v1_freq")) },
    { "size", string.format("%.2f s", params:get("v1_grain_size")) },
    { "dens", string.format("%.0f /s", params:get("v1_grain_density")) },
  }
  for field = 1, 3 do
    local label, value = field_texts(context, field)
    assert_equal(label and label.text, expected[field][1], "synth field " .. field .. " label")
    assert_equal(value and value.text, expected[field][2], "synth field " .. field .. " value")
  end
  -- buffer source: pos, size, dens
  params:set("v1_source", 3)
  redraw()
  assert_true(screen_shows(context, "buf 2"), "the buffer source")
  expected[1] = { "pos", string.format("%.2f", params:get("v1_buf_pos")) }
  for field = 1, 3 do
    local label, value = field_texts(context, field)
    assert_equal(label and label.text, expected[field][1], "buffer field " .. field .. " label")
    assert_equal(value and value.text, expected[field][2], "buffer field " .. field .. " value")
  end
  -- input source: size, dens, pitch
  params:set("v1_source", 10)
  redraw()
  assert_true(screen_shows(context, "input"), "the input source")
  expected = {
    { "size", string.format("%.2f s", params:get("v1_grain_size")) },
    { "dens", string.format("%.0f /s", params:get("v1_grain_density")) },
    { "pitch", string.format("%.2fx", params:get("v1_grain_pitch")) },
  }
  for field = 1, 3 do
    local label, value = field_texts(context, field)
    assert_equal(label and label.text, expected[field][1], "input field " .. field .. " label")
    assert_equal(value and value.text, expected[field][2], "input field " .. field .. " value")
  end
  for _, entry in ipairs(context.screen.texts) do
    assert_true(not entry.text:find("mod:", 1, true), "no mod: text: " .. entry.text)
  end
end)

test("main_fields names each source's three fields", function()
  load_strata()
  assert_equal(table.concat(main_fields(1), ","), "v1_freq,v1_grain_size,v1_grain_density", "synth")
  params:set("v4_source", 2)
  assert_equal(table.concat(main_fields(4), ","), "v4_buf_pos,v4_grain_size,v4_grain_density", "buffer")
  params:set("v4_source", 10)
  assert_equal(table.concat(main_fields(4), ","), "v4_grain_size,v4_grain_density,v4_grain_pitch", "input")
end)

test("a locked voice's values stay at full brightness", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local function levels()
    local result = {}
    for field = 1, 3 do
      local label, value = field_texts(context, field)
      result[field] = { label.level, value.level }
    end
    return result
  end
  local unlocked = levels()
  assert_equal(unlocked[1][1], 15, "the selected field's label is bright")
  assert_equal(unlocked[1][2], 15, "the selected field's value is bright")
  toggle_lock(1)
  redraw()
  local locked = levels()
  for field = 1, 3 do
    assert_equal(locked[field][1], unlocked[field][1], "field " .. field .. " label level when locked")
    assert_equal(locked[field][2], unlocked[field][2], "field " .. field .. " value level when locked")
    assert_true(locked[field][2] ~= 3, "never dimmed to 3")
  end
  -- the lock mark is bright too
  for _, entry in ipairs(texts_on_row(context, 26)) do
    if entry.text == "[L]" then assert_equal(entry.level, 15, "[L] at full brightness") end
  end
end)

test("K2 steps the field and E3 edits it", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local S = local_value("S")
  assert_equal(S.main_field, 1, "the cursor starts on the main param")
  local _, _, marker = field_texts(context, 1)
  assert_true(marker and marker.x == 65, "the cursor marks field 1")
  local freq, size = params:get("v1_freq"), params:get("v1_grain_size")
  tap(2)
  assert_equal(S.main_field, 2)
  enc(3, 2)  -- two detents: one raw quantum is half of grain size's 0.01 step
  assert_true(params:get("v1_grain_size") ~= size, "E3 edits v1_grain_size")
  assert_equal(params:get("v1_freq"), freq, "and leaves the main param alone")
  redraw()
  _, _, marker = field_texts(context, 2)
  assert_true(marker ~= nil, "the cursor marks field 2")
  assert_true(select(3, field_texts(context, 1)) == nil, "and only field 2")
  tap(2); assert_equal(S.main_field, 3)
  local density = params:get("v1_grain_density")
  enc(3, 1)
  assert_true(params:get("v1_grain_density") > density, "E3 edits v1_grain_density on field 3")
  tap(2); assert_equal(S.main_field, 1, "K2 wraps to the first field")
  enc(3, 1)
  assert_true(params:get("v1_freq") > freq, "E3 edits the main param on field 1")
  -- an input voice's field 3 is grain pitch
  params:set("v1_source", 10)
  S.main_field = 3
  local pitch = params:get("v1_grain_pitch")
  enc(3, 1)
  assert_true(params:get("v1_grain_pitch") > pitch, "E3 edits v1_grain_pitch for an input voice")
end)

test("K3 starts and stops the selected voice", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local voices, frozen = local_value("voices"), local_value("frozen")
  select_voice(3)
  assert_true(not voices[3].active, "voice 3 starts stopped")
  tap(3)
  assert_true(voices[3].active, "K3 starts it")
  tap(3)
  assert_true(not voices[3].active, "K3 stops it")
  assert_true(not frozen[3], "K3 never locks")
  -- a locked voice starts and stops too
  toggle_lock(3)
  tap(3); assert_true(voices[3].active, "K3 starts a locked voice")
  tap(3); assert_true(not voices[3].active, "K3 stops a locked voice")
  assert_true(frozen[3], "and leaves it locked")
end)

test("ALT+K3 locks and unlocks; ALT+K2 randomizes, then undoes within 5 s", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  local frozen = local_value("frozen")
  local ids = { "v1_freq", "v1_grain_size", "v1_grain_pitch" }
  local before = {}
  for _, id in ipairs(ids) do before[id] = params:get(id) end
  math.randomseed(7)
  key(1, 1)
  tap(2)
  local changed = false
  for _, id in ipairs(ids) do if params:get(id) ~= before[id] then changed = true end end
  assert_true(changed, "ALT+K2 randomizes the selected voice")
  assert_true(local_value("voices")[1].active, "the voice keeps running")
  redraw()
  assert_equal(hint_text(context), "K2:undo K3:lock")
  tap(2)
  for _, id in ipairs(ids) do assert_near(params:get(id), before[id], 1e-9, id .. " restored") end
  redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "undo used")
  -- ALT+K3 locks, then unlocks
  tap(3); assert_true(frozen[1], "ALT+K3 locks")
  assert_true(local_value("voices")[1].active, "ALT+K3 never stops the voice")
  redraw(); assert_equal(hint_text(context), "K2:locked K3:unlock")
  tap(3); assert_true(not frozen[1], "ALT+K3 unlocks")
  -- the undo window ends after 5 s
  tap(2)
  redraw(); assert_equal(hint_text(context), "K2:undo K3:lock")
  context.clock.run_for(5.01)
  redraw(); assert_equal(hint_text(context), "K2:rand K3:lock", "the undo expired")
  tap(2)  -- randomizes again, never undoes the expired one
  assert_true(undo_available(1), "ALT+K2 after the window randomizes again")
  key(1, 0)
  -- the same actions through alt_action, which every ALT press goes through
  local MAIN = local_value("S").constants.UI_PAGES.index.MAIN
  assert_true(alt_action(MAIN, 3), "MAIN has ALT actions")
  assert_true(frozen[1], "alt_action(MAIN, 3) locks")
  alt_action(MAIN, 3)
  assert_true(not frozen[1], "and unlocks")
end)

test("ALT+K2 does nothing to a locked voice", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  toggle_lock(1)
  local freq = params:get("v1_freq")
  key(1, 1); tap(2); key(1, 0)
  assert_equal(params:get("v1_freq"), freq, "a locked voice is not randomized")
  assert_true(not undo_available(1), "nothing to undo")
end)

test("ALT's K2 hint reads locked for a locked voice", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  toggle_lock(1)
  local ids = { "v1_freq", "v1_grain_size", "v1_grain_pitch" }
  local before = {}
  for _, id in ipairs(ids) do before[id] = params:get(id) end
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:locked K3:unlock", "locked voice, nothing to undo")
  tap(2)
  for _, id in ipairs(ids) do assert_equal(params:get(id), before[id], id .. " unchanged by ALT+K2") end
  key(1, 0)
  -- a voice randomized and then locked, inside the undo window, still offers undo
  select_voice(2)
  key(1, 1); tap(2); tap(3); redraw()
  assert_true(undo_available(2), "voice 2 has an undo")
  assert_equal(hint_text(context), "K2:undo K3:unlock", "undo wins over locked")
  key(1, 0)
end)

-- What randomize_voice set before #557, derived here from its draws, in
-- their order: for a synth source each synthesis param but amp at
-- spec:map(random), in the voices table's pairs order; for a buffer source
-- buf_pos r, buf_rate 2 ^ (2r - 1), buf_scan r - 0.5; then grain size
-- 0.3r + 0.05 and grain pitch 2r + 0.5. Each value as its param stores it
local function randomize_voice_draws(voice_idx, seed)
  math.randomseed(seed)
  local prefix = "v" .. voice_idx .. "_"
  local drawn = {}
  local function draw(key, value)
    local spec = params:lookup_param(prefix .. key).controlspec
    drawn[prefix .. key] = spec:map(spec:unmap(value))
  end
  if voice_uses_synth(voice_idx) then
    for key in pairs(local_value("voices")[voice_idx].params) do
      if key ~= "amp" then draw(key, params:lookup_param(prefix .. key).controlspec:map(math.random())) end
    end
  elseif voice_uses_buffer(voice_idx) then
    draw("buf_pos", math.random())
    draw("buf_rate", 2 ^ (math.random() * 2 - 1))
    draw("buf_scan", math.random() - 0.5)
  end
  draw("grain_size", math.random() * 0.3 + 0.05)
  draw("grain_pitch", math.random() * 2 + 0.5)
  return drawn
end

-- Every param's value, by id
local function all_param_values()
  local values = {}
  for _, param in ipairs(params.params) do
    if param.id and param.t ~= params.tSEPARATOR and param.t ~= params.tGROUP then values[param.id] = params:get(param.id) end
  end
  return values
end

test("MAIN's ALT+K2 acts on release and changes what randomize_voice changed before (#557)", function()
  for _, case in ipairs({ { voice = 1, source = 1, what = "resonator, synth" }, { voice = 2, source = 1, what = "fm, synth" },
    { voice = 6, source = 1, what = "karplus, synth" }, { voice = 1, source = 3, what = "buffer 2" },
    { voice = 3, source = 10, what = "input" } }) do
    local context = load_strata(); finish_startup(context)
    params:set("v" .. case.voice .. "_source", case.source)
    select_voice(case.voice)
    show_page("MAIN")
    local drawn = randomize_voice_draws(case.voice, 31)
    local before = all_param_values()
    math.randomseed(31)
    key(1, 1); key(2, 1)
    for id, value in pairs(all_param_values()) do
      assert_equal(value, before[id], case.what .. ": the press leaves " .. id)
    end
    key(2, 0); key(1, 0)
    local changed = 0
    for id, value in pairs(all_param_values()) do
      if drawn[id] then
        assert_near(value, drawn[id], 1e-9, case.what .. ": " .. id .. " takes randomize_voice's draw")
        if value ~= before[id] then changed = changed + 1 end
      else
        assert_equal(value, before[id], case.what .. ": " .. id .. " is left alone")
      end
    end
    assert_true(changed > 0, case.what .. ": the release randomized")
    assert_true(undo_available(case.voice), case.what .. ": and holds MAIN's undo")
  end
end)

test("the hint is K2:rand, K2:undo, K2:locked (#557)", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "a quick press randomizes")
  key(2, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "while K2 is down: still the quick press's")
  key(2, 0); redraw()
  assert_equal(hint_text(context), "K2:undo K3:lock", "after the randomize: undo")
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:undo K3:unlock", "a locked voice's undo still runs")
  tap(2); redraw()
  assert_equal(hint_text(context), "K2:locked K3:unlock", "undone: the locked voice offers nothing")
  local before = all_param_values()
  tap(2)
  for id, value in pairs(all_param_values()) do assert_equal(value, before[id], "locked: " .. id .. " unchanged") end
  tap(3); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "unlocked")
  -- MAIN has no hold action: a press held past 0.5 s does nothing on release
  key(2, 1); context.clock.run_for(0.6); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "held: MAIN has no hold hint")
  key(2, 0)
  for id, value in pairs(all_param_values()) do assert_equal(value, before[id], "held: " .. id .. " unchanged") end
  assert_true(not undo_available(1), "held: no undo")
  key(1, 0)
end)

test("MAIN hints follow the voice state", function()
  local context = load_strata(); finish_startup(context)
  show_page("MAIN")
  assert_equal(hint_text(context), "K2:field K3:stop", "voice 1 runs")
  select_voice(3); redraw()
  assert_equal(hint_text(context), "K2:field K3:start", "voice 3 is stopped")
  select_voice(1)
  key(1, 1); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "ALT")
  tap(2); tap(3); redraw()
  assert_equal(hint_text(context), "K2:undo K3:unlock", "ALT, randomized and locked")
  -- the undo belongs to voice 1: voice 2 offers a randomize
  select_voice(2); redraw()
  assert_equal(hint_text(context), "K2:rand K3:lock", "another voice has no undo")
  key(1, 0); redraw()
  assert_equal(hint_text(context), "K2:field K3:stop", "ALT released")
end)

test("the arc button starts and stops the voice on MAIN", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  show_page("MAIN")
  local voices, frozen = local_value("voices"), local_value("frozen")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_true(not voices[1].active, "the button stops the running voice 1")
  assert_true(not frozen[1], "and never locks it")
  context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  assert_true(voices[1].active, "the button starts it again")
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

test("MAIN voice list fits its column for every voice, state and selection (#23)", function()
  local context = load_strata(); finish_startup(context)
  local voices = local_value("voices")
  local frozen = local_value("frozen")
  local states = { { active = false, frozen = false }, { active = false, frozen = true },
    { active = true, frozen = false }, { active = true, frozen = true } }
  local entries_by_state = {}
  for state_idx, state in ipairs(states) do
    for voice_idx = 1, 7 do
      if voices[voice_idx].active ~= state.active then toggle_voice(voice_idx) end
      if (frozen[voice_idx] or false) ~= state.frozen then toggle_lock(voice_idx) end
    end
    for voice_idx = 1, 7 do
      select_voice(voice_idx)
      show_page("MAIN")
      local where = string.format("MAIN, voice %d, active %s, locked %s", voice_idx,
        tostring(state.active), tostring(state.frozen))
      assert_screen_layout(context, where)
      local voice_list = local_value("voice_list")
      local rows_drawn, selected_entry = 0, nil
      for _, entry in pairs(list_rows(context)) do
        rows_drawn = rows_drawn + 1
        if entry.level == 15 then selected_entry = entry.text end
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

test("MAIN fields fit at their widest values for every voice and source", function()
  local context = load_strata(); finish_startup(context)
  for _, source in ipairs({ 1, 9, 10 }) do
    for voice_idx = 1, 7 do
      select_voice(voice_idx)
      params:set("v" .. voice_idx .. "_source", source)
      params:set("v" .. voice_idx .. "_grain_mode", 2)
      if not local_value("frozen")[voice_idx] then toggle_lock(voice_idx) end
      for _, edge in ipairs({ "min", "max" }) do
        for _, id in ipairs(main_fields(voice_idx)) do
          local min_value, max_value = param_range(id)
          params:set(id, edge == "min" and min_value or max_value)
        end
        for field = 1, 3 do
          local_value("S").main_field = field
          show_page("MAIN")
          assert_screen_layout(context, string.format("MAIN, voice %d, source %d, %s values, field %d",
            voice_idx, source, edge, field))
        end
      end
    end
  end
end)

test("main_param_id and main_param_entry's label name each voice's E3 and arc ring 2 param", function()
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
    assert_equal(main_param_entry(voice_idx).label, key_name, "main param label of voice " .. voice_idx)
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
    -- MAIN shows the label on the first field row
    redraw()
    local label = field_texts(context, 1)
    assert_equal(label and label.text, key_name, "MAIN shows the " .. key_name .. " label")
  end
  -- an exp main param: the resonator's freq at the sweep's midpoint (200 Hz
  -- on 20-2000) is drawn at half a turn, not at its linear 9 %
  set_selected(1)
  params:set("v1_freq", 20)
  for _ = 1, local_value("UI_PAGES").ARC_TICKS_PER_SWEEP / 2 do context.arc.turn(1, 2, 1) end
  next_frame(context)
  assert_near(params:get("v1_freq"), 200, 1e-6, "half a turn reaches the exp midpoint")
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
  local label, value = field_texts(context, 1)
  assert_equal(label and label.text, "pos", "MAIN label")
  assert_equal(value and value.text, string.format("%.2f", params:get("v1_buf_pos")), "MAIN value")
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
  enc(1, 10); assert_equal(local_value("ui_page"), #h.PAGE_TITLES, "E1 stops at the last page")
  enc(1, -10); assert_equal(local_value("ui_page"), 1)
  enc(2, 1); assert_equal(local_value("selected_voice"), 2)
  local before = params:get(main_param_id(2)); enc(3, 1)
  assert_true(params:get(main_param_id(2)) ~= before, "E3 moves the main param on MAIN")
  key(3, 1); assert_true(not local_value("voices")[2].active, "K3 stops a running voice on MAIN")
  assert_true(not local_value("frozen")[2], "K3 does not lock")
end)

test("MAIN K3 and the arc button reach the screen and arc on the next frame (#11)", function()
  local context = load_strata(); finish_startup(context)
  local arc_hardware = context.arc.plug(1)
  show_page("MAIN")
  assert_drawn_on_next_frame(context, arc_hardware, "K3 on MAIN", function() key(3, 1); key(3, 0) end)
  assert_true(screen_shows(context, "OFF"), "K3 stopped voice 1")
  assert_drawn_on_next_frame(context, arc_hardware, "ALT+K3 on MAIN", function()
    key(1, 1); key(3, 1); key(3, 0); key(1, 0)
  end)
  assert_true(screen_shows(context, "[L]"), "ALT+K3 locked voice 1")
  assert_drawn_on_next_frame(context, arc_hardware, "arc button", function()
    context.arc.push(1, 1, 1); context.arc.push(1, 1, 0)
  end)
  assert_true(screen_shows(context, "ON"), "the arc button started voice 1")
end)

test("MAIN acts once per K3 press; the release does nothing", function()
  local context = load_strata(); finish_startup(context)
  select_voice(2)
  show_page("MAIN")
  key(3, 1); assert_true(not local_value("voices")[2].active, "K3 press stops on MAIN")
  key(3, 0); assert_true(not local_value("voices")[2].active, "K3 release does not restart")
end)

test("MAIN's layout states cover every voice locked, running, triggered and frozen", function()
  load_strata()
  local S = local_value("S")
  local states = S.registry.pages[S.constants.UI_PAGES.index.MAIN].layout_states
  assert_true(type(states) == "table" and #states >= 1, "MAIN lists layout states")
  local context = load_strata(); finish_startup(context)
  S = local_value("S")
  show_page("MAIN")
  S.registry.pages[S.constants.UI_PAGES.index.MAIN].layout_states[1].setup(context)
  for voice_idx = 1, 7 do
    assert_true(S.voices[voice_idx].active and S.frozen[voice_idx], "voice " .. voice_idx .. " running and locked")
    assert_equal(params:get("v" .. voice_idx .. "_grain_mode"), 2, "voice " .. voice_idx .. " triggered")
    assert_true(S.lib.freeze.is_frozen(voice_idx), "voice " .. voice_idx .. " frozen")
  end
  assert_equal(S.main_field, 3, "the cursor on field 3")
end)

test("MAIN shows [F] after [L] and [T] for a frozen voice", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  show_page("MAIN")
  local function states()
    local row = {}
    for _, entry in ipairs(texts_on_row(context, 26)) do if entry.x >= 65 then row[#row + 1] = entry end end
    return row
  end
  local function state_text()
    local words = {}
    for _, entry in ipairs(states()) do words[#words + 1] = entry.text end
    return table.concat(words, " ")
  end
  assert_equal(state_text(), "ON", "not frozen: no [F]")
  params:set("v1_freeze", 1); redraw()
  assert_equal(state_text(), "ON [F]", "frozen")
  toggle_lock(1); params:set("v1_grain_mode", 2); redraw()
  assert_equal(state_text(), "ON [L] [T] [F]", "locked, triggered and frozen, in that order")
  local row = states()
  local _, right = text_span(row[#row])
  assert_true(right <= 128, "[F] ends by x 127 (ends at " .. right .. ")")
  assert_screen_layout(context, "MAIN with ON [L] [T] [F]")
  -- a stopped voice too
  toggle_voice(1); redraw()
  assert_equal(state_text(), "OFF [L] [T] [F]", "stopped, locked, triggered and frozen")
  assert_screen_layout(context, "MAIN with OFF [L] [T] [F]")
  -- [F] is not in the voice list
  for _, entry in ipairs(context.screen.texts) do
    if entry.x < 62 then assert_true(not entry.text:find("[F]", 1, true), "the list has no [F]: " .. entry.text) end
  end
  -- unfreezing removes it
  params:set("v1_freeze", 0); redraw()
  assert_equal(state_text(), "OFF [L] [T]")
  assert_true(S.lib.freeze ~= nil)
end)

end

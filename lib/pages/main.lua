-- lib/pages/main.lua
-- The MAIN page: the voice list (S.voice_list), the selected voice's
-- details and its three fields (main_fields, the cursor S.main_field). E2
-- voice, E3 the field under the cursor, K2 next field, K3 start/stop; ALT+K2
-- randomize or undo, ALT+K3 lock/unlock. Registers its S.registry.pages
-- record. The functions that were global stay global; start_stop_selected_voice
-- is a field of this module's table (S.lib.pages_main) and the record's
-- arc_button.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local GRAIN_MODE_OPTIONS = S.constants.GRAIN_MODE_OPTIONS
  local UI_PAGES = S.constants.UI_PAGES
  local MAIN_PARAMS = S.constants.MAIN_PARAMS
  local BUFFER_MAIN_PARAM = S.constants.BUFFER_MAIN_PARAM
  local INPUT_MAIN_PARAM = S.constants.INPUT_MAIN_PARAM
  local UI = require "ui"

  -- The details column (x 65-127, right of the divider at x 62): name and
  -- source on y 18, state, [L], [T] and [F] on y 26 (fixed x, so nothing
  -- moves as they come and go; "OFF [L] [T] [F]" fills it to x 127), the three fields on y 34/42/50 (the cursor, the
  -- label, the value right-aligned). The name gives way to the source:
  -- it is cut to end name_gap px before it
  local LAYOUT = {
    left = 65, right = 127, divider_x = 62, name_y = 18, name_gap = 1,
    state_y = 26, lock_x = 84, trig_x = 99, freeze_x = 113, field_rows = {34, 42, 50}, label_x = 71,
    bright = 15, dim = 4, trig_level = 8, field_count = 3,
  }
  M.LAYOUT = LAYOUT

  -- The grain fields' labels and value formats (units included); the main
  -- param's come from main_param_entry
  local GRAIN_FIELDS = {
    grain_size = {label = "size", format = "%.2f s"},
    grain_density = {label = "dens", format = "%.0f /s"},
    grain_pitch = {label = "pitch", format = "%.2fx"},
  }

  S.voice_list = nil  -- MAIN's UI.ScrollingList, rebuilt by update_voice_list
  S.main_field = 1    -- the field E3 edits (1..LAYOUT.field_count), stepped by K2

  -- Put the list's selection on the selected voice, keeping four voices in
  -- view at both ends: ScrollingList leaves a blank top row for its first
  -- entry with one row above the selection, so the first voice gets none
  -- and the last two
  local function place_voice_list()
    S.voice_list.index = S.selected_voice
    if S.selected_voice == 1 then
      S.voice_list.num_above_selected = 0
    elseif S.selected_voice == NUM_VOICES then
      S.voice_list.num_above_selected = 2
    else
      S.voice_list.num_above_selected = 1
    end
  end

  -- MAIN's voice list: "<n><+|-> <name>", "+" for a running voice, "-" for a
  -- stopped one, the type's short name, then " [L]" when locked. Plain
  -- ASCII, so the entries' width does not depend on the font drawing other
  -- glyphs (the details column shows the full name and ON/OFF)
  function update_voice_list()
    local items = {}
    for i = 1, NUM_VOICES do
      local status = S.voices[i].active and "+" or "-"
      local lock = S.frozen[i] and " [L]" or ""
      items[i] = i .. status .. " " .. MAIN_PARAMS[S.voices[i].name].list_name .. lock
    end
    S.voice_list = UI.ScrollingList.new(0, 10, 1, items)
    S.voice_list.num_visible = 4  -- rows at y 15-48, clear of the hint row at y 62
    S.voice_list.active = true
    place_voice_list()
  end

  -- init's start step (START_ORDER.voice_list): the list MAIN draws
  S.register_start(S.constants.START_ORDER.voice_list, function()
    update_voice_list()
  end)

  function main_param_entry(voice_idx)
    if voice_uses_synth(voice_idx) then
      return MAIN_PARAMS[S.voices[voice_idx].name]
    elseif voice_uses_buffer(voice_idx) then
      return BUFFER_MAIN_PARAM
    end
    return INPUT_MAIN_PARAM
  end

  function main_param_id(voice_idx)
    return "v" .. voice_idx .. "_" .. main_param_entry(voice_idx).key
  end

  -- The three param ids MAIN shows for a voice, in field order: the main
  -- param, grain size and grain density; for an input voice, whose main
  -- param already is grain size, grain size, density and pitch
  function main_fields(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    if voice_uses_synth(voice_idx) or voice_uses_buffer(voice_idx) then
      return {main_param_id(voice_idx), prefix .. "grain_size", prefix .. "grain_density"}
    end
    return {prefix .. "grain_size", prefix .. "grain_density", prefix .. "grain_pitch"}
  end

  -- A field's label and its value as text, with the unit
  local function field_text(voice_idx, field)
    local id = main_fields(voice_idx)[field]
    local entry = GRAIN_FIELDS[id:match("^v%d+_(.*)$")]
    if field == 1 then entry = main_param_entry(voice_idx) end
    return entry.label, string.format(entry.format, params:get(id))
  end

  local function draw_details()
    local voice_idx = S.selected_voice
    local v = S.voices[voice_idx]

    -- y 18: the full name and, right-aligned, the source
    local source = voice_source_label(voice_idx)
    local name_width = LAYOUT.right - screen.text_extents(source) - LAYOUT.name_gap - LAYOUT.left
    screen.level(LAYOUT.bright)
    screen.move(LAYOUT.left, LAYOUT.name_y)
    screen.text(S.lib.ui_text.fit_text(string.upper(v.name), name_width))
    screen.level(LAYOUT.dim)
    screen.move(LAYOUT.right, LAYOUT.name_y)
    screen.text_right(source)

    -- y 26: ON/OFF, [L] when locked (full brightness), [T] in triggered
    -- mode, [F] while its audio is frozen (S.lib.freeze, full brightness)
    screen.level(LAYOUT.dim)
    screen.move(LAYOUT.left, LAYOUT.state_y)
    screen.text(v.active and "ON" or "OFF")
    if S.frozen[voice_idx] then
      screen.level(LAYOUT.bright)
      screen.move(LAYOUT.lock_x, LAYOUT.state_y)
      screen.text("[L]")
    end
    if GRAIN_MODE_OPTIONS[v.grain.mode] == "triggered" then
      screen.level(LAYOUT.trig_level)
      screen.move(LAYOUT.trig_x, LAYOUT.state_y)
      screen.text("[T]")
    end
    if S.lib.freeze.is_frozen(voice_idx) then
      screen.level(LAYOUT.bright)
      screen.move(LAYOUT.freeze_x, LAYOUT.state_y)
      screen.text("[F]")
    end

    -- y 34/42/50: the fields, the one under the cursor bright. A locked
    -- voice's values stay bright: they can still be edited
    for field = 1, LAYOUT.field_count do
      local y = LAYOUT.field_rows[field]
      local label, value = field_text(voice_idx, field)
      local selected = field == S.main_field
      screen.level(selected and LAYOUT.bright or LAYOUT.dim)
      if selected then
        screen.move(LAYOUT.left, y)
        screen.text(">")
      end
      screen.move(LAYOUT.label_x, y)
      screen.text(label)
      screen.move(LAYOUT.right, y)
      screen.text_right(value)
    end
  end

  function redraw_main()
    -- Voice list (left column, 0-60px); the selection may have moved without
    -- update_voice_list
    place_voice_list()
    S.voice_list:redraw()

    -- Right column divider
    screen.level(1)
    screen.move(LAYOUT.divider_x, 10)
    screen.line(LAYOUT.divider_x, 52)
    screen.stroke()

    draw_details()
  end

  -- What ALT+K2 does for a voice, the one decision the hint shows and the
  -- key acts on: "undo" within UNDO_SECONDS of its randomize, else "locked"
  -- (randomize leaves a locked voice alone), else "rand"
  local function alt_k2_action(voice_idx)
    if undo_available(voice_idx) then return "undo" end
    if S.frozen[voice_idx] then return "locked" end
    return "rand"
  end

  -- The hint row (redraw() draws it after the page): K2 and K3, or with ALT
  -- ALT+K2 (alt_k2_action) and ALT+K3 (lock)
  local function main_hints(alt_held)
    local voice_idx = S.selected_voice
    if alt_held then
      return "K2:" .. alt_k2_action(voice_idx) .. " K3:" .. (S.frozen[voice_idx] and "unlock" or "lock")
    end
    return "K2:field K3:" .. (S.voices[voice_idx].active and "stop" or "start")
  end

  local function main_enc(n, d)
    if n == 2 then
      S.lib.ui_keys.select_voice_by(d)
    elseif n == 3 then
      enc_param_delta(n, main_fields(S.selected_voice)[S.main_field], d)
    end
  end

  -- K3 on MAIN (and the arc button): start or stop the selected voice
  local function start_stop_selected_voice()
    toggle_voice(S.selected_voice)
  end
  M.start_stop_selected_voice = start_stop_selected_voice

  local function main_key(n)
    if n == 2 then
      S.main_field = S.main_field % LAYOUT.field_count + 1
      request_redraw()
    elseif n == 3 then
      start_stop_selected_voice()
    end
  end

  -- ALT+K2 acts on alt_k2_action: undo, randomize, or nothing for a locked
  -- voice. ALT+K3: lock/unlock
  local function main_alt_key(n)
    local voice_idx = S.selected_voice
    if n == 2 then
      local action = alt_k2_action(voice_idx)
      if action == "undo" then
        undo_randomize()
      elseif action == "rand" then
        randomize_voice(voice_idx)
      end
    elseif n == 3 then
      toggle_lock(voice_idx)
    end
    request_redraw()
  end

  -- The layout tests' and page renders' extra states: every voice running,
  -- locked, triggered and frozen with the cursor on field 3, with the first
  -- or last voice selected, and a buffer and an input source
  local function layout_state(name, selected, source)
    return {name = name, setup = function()
      local triggered
      for option, mode in ipairs(GRAIN_MODE_OPTIONS) do
        if mode == "triggered" then triggered = option end
      end
      -- the source first: a switch unfreezes
      if source then params:set("v" .. selected .. "_source", source) end
      for i = 1, NUM_VOICES do
        if not S.voices[i].active then toggle_voice(i) end
        if not S.frozen[i] then toggle_lock(i) end
        params:set("v" .. i .. "_grain_mode", triggered)
        params:set("v" .. i .. "_freeze", 1)
      end
      S.selected_voice = selected
      S.main_field = LAYOUT.field_count
      update_voice_list()
    end}
  end

  -- The page's record, at MAIN's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]. Its arc fields
  -- are lib/arc/main.lua's
  S.registry.pages[UI_PAGES.index.MAIN] = {name = "MAIN", draw = redraw_main, hints = main_hints,
    enc = main_enc, key = main_key, alt_key = main_alt_key, arc_button = start_stop_selected_voice,
    layout_states = {
      layout_state("all locked, running, triggered, frozen, field 3", 1),
      layout_state("last voice, buffer source", NUM_VOICES, S.constants.SOURCE_SYNTH + S.constants.NUM_BUFFERS),
      layout_state("resonator, input source", 1, S.constants.SOURCE_INPUT),
    }}

  return M
end

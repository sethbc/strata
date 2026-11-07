-- lib/pages/main.lua
-- The MAIN page: the voice list (S.voice_list), the selected voice's
-- details and main param, E2 voice, E3 main param, K2 randomize, K3
-- start/freeze. Registers its S.registry.pages record. The functions that
-- were global stay global; start_or_freeze_selected_voice is a field of
-- this module's table (S.lib.pages_main) for the arc button in strata.lua.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local GRAIN_MODE_OPTIONS = S.constants.GRAIN_MODE_OPTIONS
  local UI_PAGES = S.constants.UI_PAGES
  local MAIN_PARAMS = S.constants.MAIN_PARAMS
  local BUFFER_MAIN_PARAM = S.constants.BUFFER_MAIN_PARAM
  local INPUT_MAIN_PARAM = S.constants.INPUT_MAIN_PARAM
  local UI = require "ui"

  S.voice_list = nil  -- MAIN's UI.ScrollingList, rebuilt by update_voice_list

  -- MAIN's voice list: "+" for a running voice, "-" for a stopped one, then the
  -- type's short name and [F] when frozen. Plain ASCII, so the entries' width
  -- does not depend on the font drawing other glyphs (the details column shows
  -- the full name and ON/OFF).
  function update_voice_list()
    local items = {}
    for i = 1, NUM_VOICES do
      local status = S.voices[i].active and "+" or "-"
      local freeze = S.frozen[i] and " [F]" or ""
      items[i] = status .. " " .. MAIN_PARAMS[S.voices[i].name].list_name .. freeze
    end
    S.voice_list = UI.ScrollingList.new(0, 10, 1, items)
    S.voice_list.num_visible = 4  -- rows at y 15-48, clear of the hint row at y 62
    S.voice_list.num_above_selected = 1
    S.voice_list.active = true
    S.voice_list.index = S.selected_voice
  end

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

  function main_param_label(voice_idx)
    return main_param_entry(voice_idx).label
  end

  function redraw_main()
    -- Voice list (left column, 0-60px)
    S.voice_list:redraw()

    -- Right column divider
    screen.level(1)
    screen.move(62, 10)
    screen.line(62, 52)
    screen.stroke()

    -- Selected voice info (right column, 65-128px)
    local v = S.voices[S.selected_voice]
    screen.level(15)
    screen.move(65, 18)
    screen.text(string.upper(v.name))

    -- Status indicators
    screen.level(4)
    screen.move(65, 26)
    local status = v.active and "ON" or "OFF"
    screen.text(status)
    if S.frozen[S.selected_voice] then
      screen.move(127, 26)
      screen.level(8)
      screen.text_right("[FREEZE]")
    end

    -- Modulation sources display
    local mod_sources = {}
    if v.crossmod.slot1.source > 0 then table.insert(mod_sources, "V" .. v.crossmod.slot1.source) end
    if v.crossmod.slot2.source > 0 then table.insert(mod_sources, "V" .. v.crossmod.slot2.source) end
    if v.crossmod.slot3.source > 0 then table.insert(mod_sources, "V" .. v.crossmod.slot3.source) end

    if #mod_sources > 0 then
      screen.level(4)
      screen.move(65, 32)
      screen.text("mod:" .. table.concat(mod_sources, " "))
    end

    -- Main parameter
    screen.level(S.frozen[S.selected_voice] and 3 or 10)
    screen.move(65, 42)
    screen.text(main_param_label(S.selected_voice))
    if GRAIN_MODE_OPTIONS[v.grain.mode] == "triggered" then
      screen.move(127, 42)
      screen.level(8)
      screen.text_right("[TRIG]")
      screen.level(S.frozen[S.selected_voice] and 3 or 10)
    end
    screen.move(65, 50)
    screen.text(string.format(main_param_entry(S.selected_voice).format, params:get(main_param_id(S.selected_voice))))

    draw_hints("K2:rand K3:" .. (v.active and "freeze" or "start"))
  end

  local function main_enc(n, d)
    if n == 2 then
      S.lib.ui_keys.select_voice_by(d)
    elseif n == 3 then
      params:delta(main_param_id(S.selected_voice), d)
    end
  end

  -- K3 on MAIN (and the arc button): start the selected voice, or freeze it
  local function start_or_freeze_selected_voice()
    if not S.voices[S.selected_voice].active then
      toggle_voice(S.selected_voice)
    else
      toggle_freeze(S.selected_voice)
    end
  end
  M.start_or_freeze_selected_voice = start_or_freeze_selected_voice

  local function main_key(n)
    if n == 2 then
      randomize_voice(S.selected_voice)
    elseif n == 3 then
      start_or_freeze_selected_voice()
    end
  end

  -- The page's record, at MAIN's place in UI_PAGES: enc, key and redraw in
  -- strata.lua dispatch through S.registry.pages[S.ui_page]
  for index, name in ipairs(UI_PAGES) do
    if name == "MAIN" then
      S.registry.pages[index] = {name = name, draw = redraw_main, enc = main_enc, key = main_key,
        key_release = S.lib.ui_keys.ignore_page_input}
    end
  end

  return M
end

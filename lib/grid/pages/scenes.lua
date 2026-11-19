-- lib/grid/pages/scenes.lua
-- Grid page 3, scenes (3.8, design §10.5): line 1 recalls scene x at once
-- and line 2 with the transition (with SV held, either saves it instead),
-- line 3 picks the scene of the morph corner line 7 picks, lines 4 and 5
-- are the morph's X and Y faders, line 6 the sequence's length, line 7
-- SQ (the scene sequencer), SV (held to save), the corners cA-cD and the
-- gesture recorders G1-G4. Written in pane coordinates
-- (lib/grid/pane.lua), so it is the same on every layout; its state (the
-- corner picked, per port) is pane.state()'s

return function(S)
  local M = {}
  local NUM_SCENES = S.constants.NUM_SCENES
  local LEVELS = S.constants.GRID_LEVELS

  -- The lines and line 7's keys (pane coordinates), and the levels. SV is
  -- x 2, and x 16 too on a half pane showing columns 9-16 (the 64's right
  -- half, ruling 58), where x 2 is not shown
  local SCENES_PAGE = {
    lines = {recall = 1, fade = 2, corner = 3, morph = 4, morph_y = 5, length = 6, keys = 7},
    keys = {sequencer = 1, save = 2, half_save = 16, first_corner = 4, first_gesture = 9},
    line_keys = S.lib.grid_pane.LINE_KEYS,  -- a line's keys (its x bound, a fader line's keys)
    save_role = "save",
    levels = {on = LEVELS.picked, off = LEVELS.unpicked, corner_scene = 15, populated = 6, empty = 2,
      within = 8, beyond = 2, dark = 0},
  }
  M.SCENES_PAGE = SCENES_PAGE

  local lines, keys, levels = SCENES_PAGE.lines, SCENES_PAGE.keys, SCENES_PAGE.levels

  local function corners() return S.lib.morph.MORPH.corners end

  -- A param the page names is read plainly: a missing (renamed) one
  -- raises, inside the pane engine's containment, which prints it once
  local function value_of(param_id) return params:get(param_id) end

  -- The corner picked (1 = A, at first), per port
  local function corner_of(pane)
    local state = pane.state()
    state.corner = state.corner or 1
    return state.corner
  end

  local function corner_param(pane) return "morph_" .. corners()[corner_of(pane)] end

  -- Whether x 16 of line 7 is SV on this pane: a half pane that shows
  -- x 16 but not x 2 (columns 9-16)
  local function half_save(pane)
    return pane.shows(keys.half_save) and not pane.shows(keys.save)
  end

  -- SV held in its role on this pane (each pane its own; a page change of
  -- the pane forgets the role)
  local function sv_held(pane)
    if pane.pressed_as(keys.save, lines.keys, SCENES_PAGE.save_role) then return true end
    return half_save(pane) and pane.pressed_as(keys.half_save, lines.keys, SCENES_PAGE.save_role) == true
  end

  local function is_save_key(pane, x)
    return x == keys.save or (x == keys.half_save and half_save(pane))
  end

  local function corner_index(x)
    local index = x - keys.first_corner + 1
    if index >= 1 and index <= #corners() then return index end
    return nil
  end

  local function gesture_index(x)
    local index = x - keys.first_gesture + 1
    if index >= 1 and index <= S.constants.NUM_GESTURES then return index end
    return nil
  end

  -- A scene key of line 1 or 2: with SV held it saves only; else the
  -- recall waits for the quantizer (at once with quantize actions off)
  local function scene_key(pane, x, y)
    if sv_held(pane) then
      S.lib.scenes.save(x)
    elseif y == lines.recall then
      S.lib.quantize.schedule("scene", function() recall_scene(x, 0) end, "S" .. x)
    else
      local t = params:get("scene_transition_time")
      S.lib.quantize.schedule("scene", function() recall_scene(x, t) end, "S" .. x)
    end
  end

  local function line_seven_key(pane, x, z)
    local gesture = gesture_index(x)
    if gesture then
      pane.gesture_key(x, lines.keys, z, gesture)
      return
    end
    if z ~= 1 then return end
    if x == keys.sequencer then
      set_binary_param("scene_sequencer_enabled", params:get("scene_sequencer_enabled") == 1 and 0 or 1)
    elseif is_save_key(pane, x) then
      pane.press_as(x, lines.keys, SCENES_PAGE.save_role)
    elseif corner_index(x) then
      pane.state().corner = corner_index(x)
    end
  end

  local function press(pane, x, y, z)
    if type(x) ~= "number" or x < 1 or x > SCENES_PAGE.line_keys then return end
    if y == lines.keys then
      line_seven_key(pane, x, z)
      return
    end
    -- lines 1-3 and 6 name a scene or a length: x 1..NUM_SCENES
    if z ~= 1 or x > NUM_SCENES then return end
    if y == lines.recall or y == lines.fade then
      scene_key(pane, x, y)
    elseif y == lines.corner then
      params:set(corner_param(pane), x)
    elseif y == lines.length then
      params:set("scene_sequence_length", x)
    end
  end

  local function line_seven_level(pane, x)
    if x == keys.sequencer then
      return value_of("scene_sequencer_enabled") == 1 and levels.on or levels.off
    end
    if is_save_key(pane, x) then
      return pane.pressed_as(x, lines.keys, SCENES_PAGE.save_role) and levels.on or levels.off
    end
    local corner = corner_index(x)
    if corner then return corner == corner_of(pane) and levels.on or levels.off end
    local gesture = gesture_index(x)
    if gesture then return S.lib.grid_core.gesture_level(gesture) end
    return levels.dark
  end

  local function redraw(pane, led)
    local core = S.lib.grid_core
    local corner_scene = value_of(corner_param(pane))
    local length = value_of("scene_sequence_length")
    for x = 1, math.min(NUM_SCENES, SCENES_PAGE.line_keys) do
      led(x, lines.recall, core.scene_recall_level(x))
      led(x, lines.fade, core.scene_fade_level(x))
      local scene = S.scenes[x]
      local level = (scene and scene.populated) and levels.populated or levels.empty
      led(x, lines.corner, x == corner_scene and levels.corner_scene or level)
      led(x, lines.length, x <= length and levels.within or levels.beyond)
    end
    for x = 1, SCENES_PAGE.line_keys do led(x, lines.keys, line_seven_level(pane, x)) end
  end

  -- Lines 4 and 5: the morph's X and Y. A missing param raises here,
  -- inside the faders' containment, never on the engine's draw path
  local function faders()
    local found = {}
    for _, line in ipairs({{lines.morph, "morph"}, {lines.morph_y, "morph_y"}}) do
      params:lookup_param(line[2])
      found[#found + 1] = {line = line[1], first = 1, keys = SCENES_PAGE.line_keys, id = line[2]}
    end
    return found
  end

  -- What the follow compares beside the fader lines: the corner, the four
  -- corners' scenes, the length and the sequencer (all set off the grid
  -- too: MOD, the arc, a MIDI map, PARAMETERS)
  local function signature(pane)
    local parts = {corner_of(pane)}
    for _, corner in ipairs(corners()) do parts[#parts + 1] = tostring(value_of("morph_" .. corner)) end
    parts[#parts + 1] = tostring(value_of("scene_sequence_length"))
    parts[#parts + 1] = tostring(value_of("scene_sequencer_enabled"))
    return table.concat(parts, ",")
  end

  M.record = {
    name = "scenes",
    index = S.constants.GRID_PAGES.scenes,
    press = press,
    redraw = redraw,
    faders = faders,
    signature = signature,
  }
  S.register_grid_page(M.record)

  return M
end

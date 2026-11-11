-- lib/loops.lua
-- Loop regions for buffer voices: v<i>_loop_start (0-1) and v<i>_loop_length
-- (0.001-1), fractions of the slot's valid region, inside which a buffer
-- voice's grains start (bufPos, the scan and the spread move through the
-- loop and wrap in it; the engine's slotGrainPos, lib/engine/StrataLoop.sc).
-- A registered voice param record (S.register_voice_params): the loopStart
-- and loopLength grain params, continuous scene fields, and two VOICE rows
-- in a buffer voice's synth section. The start stops at 0.999 and the
-- length at 1 - start. Randomize, mutation and the fader pages never touch
-- them. See docs/notes/lua/loops.md.

return function(S)
  local M = {}

  -- The record's names and limits: the param keys (v<i>_loop_start,
  -- v<i>_loop_length), their engine grain params, the VOICE section (a
  -- buffer voice's synth section holds its buffer params), the last start
  -- (so a loop always has room for the shortest length) and that length
  M.LOOP = {
    start_key = "loop_start", length_key = "loop_length",
    start_engine = "loopStart", length_engine = "loopLength",
    section = "synth",
    max_start = 0.999, min_length = 0.001,
    -- a length within this of 1 - start fits (float rounding of the warp)
    tolerance = 1e-9,
    -- three decimals, five below fine_below (three significant digits):
    -- near 0.001 one detent of the exponential length moves it about 7%
    -- (0.00007), which three or four decimals would hide
    format = "%.3f", fine_format = "%.5f", fine_below = 0.01,
  }
  local LOOP = M.LOOP

  local function param_id(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx >= 1 and voice_idx <= S.constants.NUM_VOICES
      and voice_idx % 1 == 0
  end

  -- Whether voice voice_idx reads a buffer slot (loops are for it only)
  function M.uses_buffer(voice_idx)
    return valid_voice(voice_idx) and voice_uses_buffer(voice_idx)
  end

  -- The longest loop length the voice's start leaves room for
  function M.max_length(voice_idx)
    local start = valid_voice(voice_idx) and S.voices[voice_idx].extras[LOOP.start_key] or 0
    return 1 - (start or 0)
  end

  -- A scene recall or transition sets the registered fields in sorted key
  -- order (lib/scenes.lua, #531), so loop_length comes before loop_start.
  -- The length's filter stands down while a scene sets them (clamped to the
  -- old start's room, a recall from (0.5, 0.5) to (0, 1) would end at
  -- (0, 0.5)), and the start, set after it, has the last word: its action
  -- cuts a length the new start leaves no room for
  local function scene_setting()
    return S.scene_recall_in_progress == true or S.scene_transition_active == true
  end

  -- The start stops at max_start
  S.register_param_filter(LOOP.start_key, function(_, value)
    return math.min(value, LOOP.max_start)
  end)
  -- The length stops at 1 - start (except while a scene sets them, above)
  S.register_param_filter(LOOP.length_key, function(voice_idx, value)
    if scene_setting() then return value end
    return math.min(value, M.max_length(voice_idx))
  end)

  -- After a start change: a length that no longer fits is cut to 1 - start
  local function clamp_length(voice_idx)
    local id = param_id(voice_idx, LOOP.length_key)
    local limit = M.max_length(voice_idx)
    if params:get(id) > limit + LOOP.tolerance then params:set(id, limit) end
  end

  local function fraction_text(param)
    local value = param:get()
    return string.format(value < LOOP.fine_below and LOOP.fine_format or LOOP.format, value)
  end

  -- VOICE's layout tests and page renders: every voice on buffer 1, a loop
  -- at the slot's end, the cursor on each loop row
  local layout_states = {}
  for voice_idx = 1, S.constants.NUM_VOICES do
    for _, key in ipairs({LOOP.start_key, LOOP.length_key}) do
      table.insert(layout_states, {
        name = string.format("v%d buffer %s", voice_idx, (key:gsub("_", " "))),
        setup = function()
          S.selected_voice = voice_idx
          params:set(param_id(voice_idx, "source"), S.constants.SOURCE_SYNTH + 1)
          params:set(param_id(voice_idx, LOOP.start_key), 1)
          S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id(voice_idx, key)))
        end,
      })
    end
  end

  -- A scene's loop pair as the params would leave it (a hand-edited file
  -- may hold any pair): the start at most max_start, the length at most
  -- 1 - start. migrate_scene runs it on every loaded scene, so a recall,
  -- whose length is not clamped while it sets the fields, still ends inside
  -- the slot. Anything but two numbers is left for validate_scene
  local function normalize_scene(extras)
    local start, length = extras[LOOP.start_key], extras[LOOP.length_key]
    if type(start) ~= "number" or type(length) ~= "number" or start ~= start or length ~= length then return end
    start = math.min(start, LOOP.max_start)
    extras[LOOP.start_key] = start
    if length > 1 - start + LOOP.tolerance then extras[LOOP.length_key] = 1 - start end
  end

  local record
  record = {
    name = "loops",
    count = 2,
    add = function(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, record, LOOP.start_key, {
        type = "control",
        name = "loop start",
        controlspec = controlspec.new(0, 1, "lin", 0, 0),
        formatter = fraction_text,
        action = function() clamp_length(voice_idx) end,
      })
      -- exponential, so short loops get fine steps
      S.lib.params_setup.add_voice_extra(voice_idx, record, LOOP.length_key, {
        type = "control",
        name = "loop length",
        controlspec = controlspec.new(LOOP.min_length, 1, "exp", 0, 1),
        formatter = fraction_text,
      })
    end,
    grain_keys = {[LOOP.start_key] = LOOP.start_engine, [LOOP.length_key] = LOOP.length_engine},
    scene_defaults = {[LOOP.start_key] = 0, [LOOP.length_key] = 1},
    normalize_scene = normalize_scene,
    voice_rows = {
      section = LOOP.section,
      rows = {LOOP.start_key, LOOP.length_key},
      when = function(voice_idx) return M.uses_buffer(voice_idx) end,
    },
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)

  return M
end

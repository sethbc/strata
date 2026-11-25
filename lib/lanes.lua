-- lib/lanes.lua
-- The value lanes (3.9 grid sequencer, package 2a, design section 2, The
-- values and Move's values; S.lib.lanes): a voice's two move targets
-- (v<i>_seq_move_a, auto or one of TARGETS; v<i>_seq_move_b, off or one of
-- them: params of lib/sequencer.lua's seq record), the target each lane
-- names now, what a value of 1 to 15 sets on each target, the hand's
-- choices of a mode and a target (the grid's keys and SEQ's row; the
-- params' own actions do neither extra), and the light of a hit on the
-- grid. A step's values are its step keys va and vb (lib/sequencer.lua's
-- ATTR_CHECKS); the sequencer sets and holds them (held_value). Nothing
-- here is stored and nothing is sent but through params. See
-- docs/notes/lua/lanes.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local PATTERN_LENGTH = S.constants.PATTERN_LENGTH
  local MAX_STEP_LEVEL = S.constants.MAX_STEP_LEVEL

  -- The four targets, in the params' order after their first option
  M.TARGETS = {"position", "pitch", "size", "cutoff"}

  -- The lanes' params, step keys and first options; the param each target
  -- moves (pitch: the note path's, see M.value); a move hit's light
  -- with no value A; the flash of a filter opened by choose_target
  local MOVE = {
    param = {a = "seq_move_a", b = "seq_move_b"},
    step_key = {a = "va", b = "vb"},
    first = {a = "auto", b = "off"},
    moves = {position = "buf_pos", size = "grain_size", cutoff = "filter_freq"},
    no_value_light = 4,
    own_pitch_level = 8,  -- 2b: a pitch value of 8 is the voice's own pitch; level - 8 are its degrees
    filter_open = 1,
    filter_flash = "filter on",
  }
  M.MOVE = MOVE

  -- Each lane's options: its first, then the four targets
  function M.options(lane)
    local options = {MOVE.first[lane]}
    for _, target in ipairs(M.TARGETS) do options[#options + 1] = target end
    return options
  end

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx == math.floor(voice_idx) and voice_idx >= 1
      and voice_idx <= NUM_VOICES
  end

  local function voice_param(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  -- The option a lane's param holds, by name
  local function option(voice_idx, lane)
    return M.options(lane)[params:get(voice_param(voice_idx, MOVE.param[lane]))]
  end

  -- The target lane "a" or "b" of the voice names now: auto is position on
  -- a buffer voice and pitch on any other; off is nil; B is nil where it
  -- names A's target (A's value is set, B's lane does nothing)
  function M.target(voice_idx, lane)
    if not valid_voice(voice_idx) or MOVE.param[lane] == nil then return nil end
    local name = option(voice_idx, lane)
    if name == "auto" then name = voice_uses_buffer(voice_idx) and "position" or "pitch" end
    if name == "off" then return nil end
    if lane == "b" and name == M.target(voice_idx, "a") then return nil end
    return name
  end

  -- What a value of level (a whole 1 to MAX_STEP_LEVEL) sets: the param id
  -- and its value, the level (level - 1) / 14 of the way along. Position:
  -- v<i>_buf_pos, which is a fraction of the voice's loop (0 its start, 1
  -- its end; docs/notes/engine/loops.md); size and cutoff: the param's own
  -- scale (its controlspec's map). Pitch (2b): level - 8 degrees from the
  -- voice's own pitch, on the param a step's note moves for its source (a
  -- synth voice's freq, a buffer voice's rate, an input voice's grain
  -- pitch: S.lib.sequencer.note_value). nil for another target or a level
  -- out of range
  function M.value(voice_idx, target, level)
    if not valid_voice(voice_idx) or (MOVE.moves[target] == nil and target ~= "pitch") then return nil end
    if type(level) ~= "number" or level ~= math.floor(level) or level < 1 or level > MAX_STEP_LEVEL then return nil end
    if target == "pitch" then return S.lib.sequencer.note_value(voice_idx, level - MOVE.own_pitch_level) end
    local fraction = (level - 1) / (MAX_STEP_LEVEL - 1)
    local param_id = voice_param(voice_idx, MOVE.moves[target])
    if target == "position" then return param_id, fraction end
    return param_id, params:lookup_param(param_id).controlspec:map(fraction)
  end

  local function index_of(list, name)
    for index, entry in ipairs(list) do
      if entry == name then return index end
    end
    return nil
  end

  -- The hand's choice of a mode (the grid's keys, SEQ's row): the mode set;
  -- for move, each set step of 1 to the voice's length that has no value A
  -- is given a random one, so the mode is heard at once. An unknown voice
  -- or mode does nothing
  function M.choose_mode(voice_idx, name)
    local seq = S.lib.sequencer
    local index = valid_voice(voice_idx) and index_of(seq.SEQ.modes, name)
    if not index then return end
    params:set(voice_param(voice_idx, "seq_gate"), index)
    if name ~= "move" then return end
    for step = 1, params:get(voice_param(voice_idx, "seq_length")) do
      if S.patterns[voice_idx][step] > 0 and seq.step_attr(voice_idx, step, MOVE.step_key.a) == nil then
        seq.set_step_attr(voice_idx, step, MOVE.step_key.a, math.random(1, MAX_STEP_LEVEL))
      end
    end
  end

  -- The hand's choice of a lane's target: the param set; for cutoff on a
  -- voice whose filter mix is 0, the mix set to 1 and a flash, since the
  -- filter would otherwise do nothing. An unknown voice, lane or name does
  -- nothing
  function M.choose_target(voice_idx, lane, name)
    if not valid_voice(voice_idx) or MOVE.param[lane] == nil then return end
    local index = index_of(M.options(lane), name)
    if not index then return end
    params:set(voice_param(voice_idx, MOVE.param[lane]), index)
    local mix = voice_param(voice_idx, "filter_mix")
    if name == "cutoff" and params:get(mix) == 0 then
      params:set(mix, MOVE.filter_open)
      S.lib.ui_flash.start("header", MOVE.filter_flash)
    end
  end

  -- A hit's light on the grid's pages: step_brightness in every mode but
  -- move; in move a set step inside the length and off the playhead lights
  -- at its value A, or MOVE.no_value_light with none (the playhead and the
  -- steps past the length light as in every mode). SEQ keeps
  -- step_brightness. 0 for a voice or step out of range
  function M.hit_light(voice_idx, step)
    if not valid_voice(voice_idx) or type(step) ~= "number" or step < 1 or step > PATTERN_LENGTH
        or step ~= math.floor(step) then
      return 0
    end
    local seq = S.lib.sequencer
    local light = step_brightness(voice_idx, step)
    if seq.step_mode(voice_idx) ~= "move" or S.patterns[voice_idx][step] == 0
        or step > params:get(voice_param(voice_idx, "seq_length")) or step == seq.sounding_step(voice_idx) then
      return light
    end
    return seq.step_attr(voice_idx, step, MOVE.step_key.a) or MOVE.no_value_light
  end

  return M
end

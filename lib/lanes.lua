-- lib/lanes.lua
-- The value lanes (3.9 grid sequencer, package 2a, design section 2, The
-- values and Move's values; S.lib.lanes): a voice's two move targets
-- (v<i>_seq_move_a, auto or one of TARGETS; v<i>_seq_move_b, off or one of
-- them: params of lib/sequencer.lua's seq record), the target each lane
-- names now, what a value of 1 to 15 sets on each target, the hand's
-- choices of a mode and a target (the grid's keys and SEQ's row; the
-- params' own actions do neither extra), and the light of a hit on the
-- grid. A step's values are its step keys va and vb (lib/sequencer.lua's
-- ATTR_CHECKS); the sequencer sets and holds them (held_value). Package
-- 2c (Following and free, Lane lengths): the five lanes a hit reads (A, B,
-- chance, repeats, gate), each following (read at the step played) or free
-- at a length of its own (read at its own position, which moves on at
-- every tick the voice takes), and the scene block lanes that keeps the
-- lengths. Nothing here is sent but through params. See
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

  -- Lane lengths (package 2c, design section 2, Following and free, Lane
  -- lengths) -------------------------------------------------------------

  -- The five lanes a hit reads beside its hits, in order, and the step key
  -- each one's cells are (the sixteen steps' own keys: no second store)
  M.LANES = {"a", "b", "chance", "repeats", "gate"}
  M.STEP_KEYS = {a = MOVE.step_key.a, b = MOVE.step_key.b, chance = "prob", repeats = "ratchet", gate = "gate"}

  -- Per voice: each free lane's length (1 to PATTERN_LENGTH; absent: it
  -- follows), its position (the cell its next read reads, 1 to its length;
  -- absent while it follows) and the cell it read last (sounding)
  local lane_state = {lengths = {}, positions = {}, sounding = {}}
  for voice_idx = 1, NUM_VOICES do
    lane_state.lengths[voice_idx], lane_state.positions[voice_idx], lane_state.sounding[voice_idx] = {}, {}, {}
  end

  local function is_lane(lane) return M.STEP_KEYS[lane] ~= nil end

  local function valid_length(n)
    return type(n) == "number" and n == math.floor(n) and n >= 1 and n <= PATTERN_LENGTH
  end

  -- A lane's length, or nil while it follows (or for no voice or lane)
  function M.length(voice_idx, lane)
    if not valid_voice(voice_idx) or not is_lane(lane) then return nil end
    return lane_state.lengths[voice_idx][lane]
  end

  -- A free lane's position, the cell its next read reads; nil while it follows
  function M.position(voice_idx, lane)
    if not valid_voice(voice_idx) or not is_lane(lane) then return nil end
    return lane_state.positions[voice_idx][lane]
  end

  -- Set a lane's length: n (whole, 1 to PATTERN_LENGTH) frees it, nil makes
  -- it follow. A lane freed starts at 1; a free one keeps its position, but
  -- wraps to 1 when the new length is below it. Anything else does
  -- nothing. A change ends the voice's pattern undo, as a step's edit does,
  -- and redraws the grid
  function M.set_length(voice_idx, lane, n)
    if not valid_voice(voice_idx) or not is_lane(lane) or (n ~= nil and not valid_length(n)) then return end
    local lengths, positions = lane_state.lengths[voice_idx], lane_state.positions[voice_idx]
    if lengths[lane] == n then return end
    lengths[lane] = n
    if n == nil then
      positions[lane] = nil
    elseif positions[lane] == nil or positions[lane] > n then
      positions[lane] = 1
    end
    S.lib.mutation.note_pattern_edit(voice_idx)
    grid_redraw()
  end

  -- A copy of the voice's lengths, lane -> length for each free lane (the
  -- whole-pattern door, package 4a), or nil for no voice
  function M.lengths(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    local copy = {}
    for lane, n in pairs(lane_state.lengths[voice_idx]) do copy[lane] = n end
    return copy
  end

  -- Set all five of the voice's lengths from such a table: a lane it does
  -- not name, or names with no whole 1 to PATTERN_LENGTH, follows
  function M.set_lengths(voice_idx, lengths)
    if not valid_voice(voice_idx) or type(lengths) ~= "table" then return end
    for _, lane in ipairs(M.LANES) do
      local n = lengths[lane]
      M.set_length(voice_idx, lane, valid_length(n) and n or nil)
    end
  end

  -- The lane's value at the hit: its step key at hit_step while it follows,
  -- at its own position while it is free. The cell read is recorded
  -- (sounding). Read once a tick, at the tick's begin
  -- (lib/sequencer.lua's begin_voice_step); nil for no value, voice or lane
  function M.read(voice_idx, lane, hit_step)
    if not valid_voice(voice_idx) or not is_lane(lane) then return nil end
    local cell = lane_state.positions[voice_idx][lane] or hit_step
    if type(cell) ~= "number" or cell < 1 or cell > PATTERN_LENGTH then return nil end
    lane_state.sounding[voice_idx][lane] = cell
    return M.last_read(voice_idx, lane)
  end

  -- The cell the lane read last (the lights), or nil before its first read
  -- since the voice's start
  function M.sounding(voice_idx, lane)
    if not valid_voice(voice_idx) or not is_lane(lane) then return nil end
    return lane_state.sounding[voice_idx][lane]
  end

  -- The value the lane's last read cell holds now: what the rest of the
  -- tick reads (the step's first hit's outputs, a ratchet's later hits),
  -- after advance has moved the position on. nil with none
  function M.last_read(voice_idx, lane)
    local cell = M.sounding(voice_idx, lane)
    local attrs = cell and S.pattern_steps[voice_idx][cell]
    return attrs and attrs[M.STEP_KEYS[lane]]
  end

  -- The voice starts (start_position: a pattern start, a restart, a
  -- division reset's bar, a stop): every free lane back to 1, nothing read
  function M.start(voice_idx)
    if not valid_voice(voice_idx) then return end
    for lane in pairs(lane_state.lengths[voice_idx]) do lane_state.positions[voice_idx][lane] = 1 end
    lane_state.sounding[voice_idx] = {}
  end

  -- A tick the voice took, played or skipped, after its reads: every free
  -- lane forward by one, wrapping at its length
  function M.advance(voice_idx)
    if not valid_voice(voice_idx) then return end
    local positions = lane_state.positions[voice_idx]
    for lane, n in pairs(lane_state.lengths[voice_idx]) do positions[lane] = positions[lane] % n + 1 end
  end

  -- Whether a lanes block (design section 6) holds NUM_VOICES tables, each
  -- of lane names to whole lengths 1 to PATTERN_LENGTH
  local function valid_block(block)
    if type(block) ~= "table" then return false end
    for voice_idx, lengths in pairs(block) do
      if not valid_voice(voice_idx) or type(lengths) ~= "table" then return false end
      for lane, n in pairs(lengths) do
        if not is_lane(lane) or not valid_length(n) then return false end
      end
    end
    for voice_idx = 1, NUM_VOICES do
      if type(block[voice_idx]) ~= "table" then return false end
    end
    return true
  end
  M.valid_block = valid_block  -- 4a: a stored letter's lanes are held to it (lib/pattern_letters.lua)

  -- Every voice's lengths from a (valid) lanes block: a recall's, a chain
  -- link's (lib/sequencer.lua's load_chain_scene), a chain start's undo;
  -- but the voices in skip (a set by voice, a recall's: a fade's released
  -- voices keep theirs, #1050)
  function M.apply_block(block, skip)
    for voice_idx = 1, NUM_VOICES do
      if not (skip and skip[voice_idx]) then M.set_lengths(voice_idx, block[voice_idx] or {}) end
    end
  end

  -- The lanes scene block: per voice its free lanes' lengths, by name;
  -- switched at a transition's end, before the steps block. A scene
  -- without it is filled with seven empty tables: every lane follows
  S.register_scene_block({
    key = "lanes",
    default = function()
      local block = {}
      for voice_idx = 1, NUM_VOICES do block[voice_idx] = {} end
      return block
    end,
    capture = function()
      local block = {}
      for voice_idx = 1, NUM_VOICES do block[voice_idx] = M.lengths(voice_idx) end
      return block
    end,
    validate = valid_block,
    apply = M.apply_block,
    discrete = true,
  })

  return M
end

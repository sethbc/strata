-- lib/mutation.lua
-- Per-voice drift (drift_update, on the 10 Hz S.drift_metro: a slow random
-- walk of grain pitch and buffer position; not the global LFOs), randomize
-- (S.lib.mutation.randomize(spec), every page's, and MAIN's randomize_voice,
-- with one undo for the whole script: S.undo, S.lib.mutation.undo) and
-- mutations (gentle_mutate, on S.mutation_metro).
-- The functions stay global. The metros are created by this module's start
-- steps (S.register_start, at the end of this file) and stopped by its
-- cleanup steps.
-- S.grain_pitch_base and S.buf_pos_base (the walk's centers) are also set by
-- the grain pitch and buffer position param actions, so they live on S, as
-- does S.drift_writing, which those actions and redraw_on_param_changes read.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local UNDO_SECONDS = S.constants.UNDO_SECONDS

  -- Per-voice drift (drift_update on the 10 Hz drift_metro): a slow random
  -- walk of grain pitch and buffer position. Not the global LFOs (S.lfos).
  S.drift_metro = nil
  local DRIFT_PITCH_STEP = 0.004       -- width of each random grain pitch step (+/-0.002 per tick)
  local DRIFT_PITCH_REVERSION = 0.01   -- fraction of the offset from the base pitch removed per tick
  S.grain_pitch_base = {}              -- last non-drift grain pitch per voice (the walk's center)
  local DRIFT_BUF_POS_STEP = 0.002     -- width of each random buffer position step (+/-0.001 per tick)
  local DRIFT_BUF_POS_REVERSION = 0.01 -- fraction of the offset from the base position removed per tick
  S.buf_pos_base = {}                  -- last non-drift buffer position per voice
  S.drift_writing = false              -- true while drift_update sets params
  for i = 1, NUM_VOICES do
    S.grain_pitch_base[i] = S.voices[i].values.grain_pitch
    S.buf_pos_base[i] = S.voices[i].values.buf_pos
  end

  -- Mutation system
  S.mutation_metro = nil

  -- The randomize undo, one for the whole script (#557): S.undo = {page,
  -- section, voice (nil off a voice's page), values = {[param_id] = the
  -- value before the randomize}, ids = the values' ids in the order the
  -- randomize set them, pattern = {voice, steps, values_a} (a pattern
  -- spec's old steps and their values A) or nil, until_time = util.time() at which it expires}, or nil; 3.9
  -- (#922, #927) adds three holds: patterns = {[voice] = levels} and steps =
  -- {[voice] = {[step] = attributes}} (a chain start's, hold_patterns; its
  -- per-voice chain keys in values and ids), sequence = {n, values} (a
  -- random sequence's new, hold_sequence) and routing = {k, source, dest,
  -- param, before} (a learn's rewire, hold_routing; its depth in values and
  -- ids), each nil when not held. undo_clock
  -- wakes at until_time to clear it and ask for a redraw (the ALT hint goes
  -- back without input); it runs on the clock helper (S.lib.clocks, #870):
  -- undo_handle is its handle and undo_clock its id (the tests read it),
  -- both nil while none runs. undo_writing is true while a randomize or the
  -- undo writes, so note_param_edit and note_pattern_edit do not take their
  -- writes for an edit.
  S.undo = nil
  local undo_handle = nil
  local undo_clock = nil
  local undo_writing = false

  -- Run writes (a function setting params) as randomize's or undo's. The flag
  -- is put back as it was found, so a write nested in another leaves the
  -- outer's set (#892), and it must not outlive an error in a param action
  -- (every later edit would keep the undo): put it back, then raise the
  -- error again, with its traceback
  local function write_as_undo(writes)
    local outer = undo_writing
    undo_writing = true
    local written, write_error = xpcall(writes, with_traceback)
    undo_writing = outer
    if not written then error(write_error, 0) end
  end

  -- Stop the expiry clock: S.lib.clocks.stop cancels it, or retires it when
  -- its wake may be posted, and the retired clock's wake then does nothing
  function clear_undo()
    if undo_handle then
      S.lib.clocks.stop(undo_handle)
      undo_handle, undo_clock = nil, nil
    end
    if S.undo then
      S.undo = nil
      request_redraw()
    end
  end

  -- Set a param a randomize draws or the undo restores: a binary one through
  -- set_binary_param, so a controller mapped to it follows (#538)
  local function set_randomized_param(param_id, value)
    if params:lookup_param(param_id).t == params.tBINARY then
      set_binary_param(param_id, value)
    else
      params:set(param_id, value)
    end
  end

  local function is_index(value, count)
    return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= count
  end

  -- A spec a page hands randomize: {page, section, voice, draws} or {page,
  -- section, voice, pattern}. A malformed one is a bug in its page: an error
  local function check_spec(spec)
    local function require_spec(holds, problem)
      if not holds then error("randomize: " .. problem, 4) end
    end
    require_spec(type(spec) == "table", "a spec is a table")
    require_spec(is_index(spec.page, S.constants.NUM_UI_PAGES), "page is a UI_PAGES index")
    require_spec(type(spec.section) == "string", "section is a string")
    require_spec(spec.voice == nil or is_index(spec.voice, NUM_VOICES), "voice is a voice index or nil")
    if spec.pattern ~= nil then
      require_spec(is_index(spec.pattern, NUM_VOICES), "pattern is a voice index")
      return
    end
    require_spec(type(spec.draws) == "table", "a spec has draws or a pattern")
    for _, entry in ipairs(spec.draws) do
      require_spec(type(entry) == "table" and type(entry.id) == "string" and params.lookup[entry.id] ~= nil
        and type(entry.draw) == "function", "each draw is {id = a param id, draw = fn}")
    end
  end

  -- Hold the undo of the randomize just made (or, 3.8, of a voice preset's
  -- load: capture), for UNDO_SECONDS. A clock still running (an undo held
  -- inside this one's own write: a nested randomize) is stopped before its
  -- replacement starts, so it never clears the new undo at its own wake
  -- held: the 3.9 holds' fields (patterns and steps, sequence, routing), or nil
  local function hold_undo(spec, values, ids, pattern, capture, held)
    S.lib.clocks.stop(undo_handle)
    S.undo = {page = spec.page, section = spec.section, voice = spec.voice, values = values, ids = ids,
      pattern = pattern, capture = capture, until_time = util.time() + UNDO_SECONDS}
    for key, value in pairs(held or {}) do S.undo[key] = value end
    undo_handle = S.lib.clocks.run(function(handle)
      if not handle.sleep(UNDO_SECONDS) then return end
      undo_handle, undo_clock = nil, nil  -- first: clear_undo would stop this clock
      clear_undo()
    end)
    undo_clock = undo_handle.id
  end

  -- A pattern spec: randomize_pattern(voice), its old steps held, and
  -- (fx2, #1054) each step's value A, which a randomize in move gives the
  -- steps it turns on: values_a = {[step] = va}, nil where a step had none
  local function randomize_pattern_spec(spec)
    local voice_idx = spec.pattern
    local steps, values_a = {}, {}
    for step, level in ipairs(S.patterns[voice_idx]) do
      steps[step] = level
      values_a[step] = S.lib.sequencer.step_attr(voice_idx, step, "va")
    end
    clear_undo()
    write_as_undo(function() randomize_pattern(voice_idx) end)
    hold_undo(spec, {}, {}, {voice = voice_idx, steps = steps, values_a = values_a})
    request_redraw()
    grid_redraw()
    return true
  end

  -- Randomize what a spec names, holding its undo (it replaces any earlier
  -- one). draws: each {id, draw} in order, draw() called just before its set
  -- (so a later draw may read an earlier one's new value), every old value
  -- held before the first set (an action may change a later id: a loop
  -- start's cuts its length); every set reaches the engine through the
  -- param's action.
  -- pattern = <voice>: that voice's pattern, through randomize_pattern (lock
  -- covers params, not patterns). Returns false, changing nothing, for a
  -- draws spec of a locked voice or with no draws
  function M.randomize(spec)
    check_spec(spec)
    if spec.pattern ~= nil then return randomize_pattern_spec(spec) end
    if spec.voice ~= nil and S.locked[spec.voice] then return false end
    if #spec.draws == 0 then return false end
    local values, ids = {}, {}
    for _, entry in ipairs(spec.draws) do
      if values[entry.id] == nil then
        values[entry.id] = params:get(entry.id)
        ids[#ids + 1] = entry.id
      end
    end
    clear_undo()
    write_as_undo(function()
      for _, entry in ipairs(spec.draws) do set_randomized_param(entry.id, entry.draw()) end
    end)
    hold_undo(spec, values, ids, nil)
    request_redraw()
    grid_redraw()
    return true
  end

  -- Whether a quick ALT+K2 on page `page`, section `section`, voice `voice`
  -- (nil off a voice's page) would undo: the undo held is that one's (a
  -- held voice undo, 3.8: any section of its page and voice; a chain
  -- start's patterns, 3.9: any voice of its section) and its window has
  -- not ended
  function M.undo_for(page, section, voice)
    local undo = S.undo
    return undo ~= nil and undo.page == page and (undo.section == section or undo.capture ~= nil)
      and (undo.voice == voice or undo.patterns ~= nil) and util.time() < undo.until_time
  end

  -- 3.9 (#922, #927): the holds made outside a page randomize. where is
  -- {page = a UI_PAGES index, section = a string}: the undo is held there
  -- (undo_for), with no voice. A malformed call is a bug in its caller
  local function check_where(where, name)
    if type(where) ~= "table" or not is_index(where.page, S.constants.NUM_UI_PAGES)
      or type(where.section) ~= "string" then
      error(name .. ": where is {page, section}", 3)
    end
  end

  -- Two values alike, tables by their contents
  local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do
      if not same(value, b[key]) then return false end
    end
    for key in pairs(b) do
      if a[key] == nil then return false end
    end
    return true
  end

  -- A copy of a table of plain values and tables of them
  local function copy_of(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, inner in pairs(value) do copy[key] = copy_of(inner) end
    return copy
  end

  -- What a chain start can replace: every voice's levels, step attributes,
  -- the keys a link carries (S.lib.sequencer.SEQ.chain_keys), (3.9's 2c)
  -- its lanes' lengths and (4a) its letters (S.lib.pattern_letters' block)
  local function capture_patterns()
    local patterns, steps, values, ids, lanes = {}, {}, {}, {}, {}
    for voice_idx = 1, NUM_VOICES do
      patterns[voice_idx] = copy_of(S.patterns[voice_idx])
      steps[voice_idx] = copy_of(S.pattern_steps[voice_idx] or {})
      lanes[voice_idx] = S.lib.lanes.lengths(voice_idx)
      for _, key in ipairs(S.lib.sequencer.SEQ.chain_keys) do
        local param_id = "v" .. voice_idx .. "_" .. key
        values[param_id] = params:get(param_id)
        ids[#ids + 1] = param_id
      end
    end
    return patterns, steps, values, ids, lanes, S.lib.pattern_letters.capture()
  end

  -- Hold all seven patterns, their step attributes, lane lengths and
  -- letters and each voice's chain keys around writes (a chain start's link, lib/sequencer.lua): captured
  -- before, the writes made as the undo's own (their pattern and param
  -- edits end nothing), then held at where when they changed any of it.
  -- Writes that change nothing leave an earlier undo as it was. Returns
  -- whether it holds
  function M.hold_patterns(where, writes)
    check_where(where, "hold_patterns")
    if type(writes) ~= "function" then error("hold_patterns: writes is a function", 2) end
    local patterns, steps, values, ids, lanes, letters = capture_patterns()
    write_as_undo(writes)
    local now_patterns, now_steps, now_values, _, now_lanes, now_letters = capture_patterns()
    if same(patterns, now_patterns) and same(steps, now_steps) and same(values, now_values)
      and same(lanes, now_lanes) and same(letters, now_letters) then
      return false
    end
    clear_undo()
    hold_undo(where, values, ids, nil, nil,
      {patterns = patterns, steps = steps, lanes = lanes, letters = letters})
    request_redraw()
    grid_redraw()
    return true
  end

  -- Hold random sequence n's sixteen values (S.lib.random_sequences) at
  -- where, before its new draws them again
  function M.hold_sequence(n, where)
    check_where(where, "hold_sequence")
    local values = S.lib.random_sequences.values(n)
    if not values then error("hold_sequence: a sequence number", 2) end
    clear_undo()
    hold_undo(where, {}, {}, nil, nil, {sequence = {n = n, values = values}})
    request_redraw()
  end

  -- Hold matrix routing k (its source and destination), its depth param
  -- depth_id and the touched param_id's value before the touch (the touch
  -- hooks' third argument; nil holds none) around writes (a learn's rewire,
  -- lib/matrix.lua), at where, when the writes changed the routing or its
  -- depth (a learn that changes nothing leaves an earlier undo). Both
  -- params are held as values, so an edit of either ends the undo, but the
  -- turn that learned going on (note_param_edit: the detent path's own set
  -- of the touched param, S.lib.ui_detent.detent_param()), and the undo
  -- puts back the value from before it. Returns whether it holds
  function M.hold_routing(k, where, writes, depth_id, param_id, before)
    check_where(where, "hold_routing")
    local matrix = S.lib.matrix
    local routing = matrix.routing(k)
    if not routing or type(writes) ~= "function" or params.lookup[depth_id] == nil then
      error("hold_routing: a routing, writes and its depth param", 2)
    end
    write_as_undo(writes)
    local now = matrix.routing(k)
    if now.source == routing.source and now.dest == routing.dest and now.depth == routing.depth then return false end
    local values, ids = {[depth_id] = routing.depth}, {depth_id}
    if param_id ~= nil and before ~= nil and params.lookup[param_id] then
      values[param_id] = before
      ids[2] = param_id
    end
    clear_undo()
    hold_undo(where, values, ids, nil, nil, {routing = {k = k, source = routing.source, dest = routing.dest,
      param = param_id}})
    request_redraw()
    return true
  end

  -- 3.8 (package 3b, design §8.3, ruling 46 as amended): the held voice
  -- undo. After a voice preset's load or copy has applied, hold the
  -- voice's sound from before it, capture = {type, values} holding what a
  -- load can change (the type's synth keys and the In keys: S.lib.voice_presets'
  -- filtered capture), as the one undo, VOICE's, for UNDO_SECONDS. values
  -- names every v<i>_<key> of the capture and of the voice's synth keys
  -- now (the loaded type's), so an edit of the old or the new sound
  -- (note_param_edit) ends it; an Out key's write does not. The capture's
  -- preset_name (a string or nil) is the name the voice's preset row showed
  -- before, which the undo puts back (#869). Called after the apply, whose
  -- own param actions are edits
  function M.hold_voice(voice_idx, capture)
    if not is_index(voice_idx, NUM_VOICES) or type(capture) ~= "table" or type(capture.values) ~= "table" then
      error("hold_voice: a voice index and its capture", 2)
    end
    clear_undo()
    local prefix = "v" .. voice_idx .. "_"
    local values = {}
    for key, value in pairs(capture.values) do values[prefix .. key] = value end
    for _, entry in ipairs((S.lib.params_setup.voice_scene_keys(voice_idx))) do
      if entry.synth and values[prefix .. entry.key] == nil then
        values[prefix .. entry.key] = S.voices[voice_idx].values[entry.key]
      end
    end
    hold_undo({page = S.constants.UI_PAGES.index.VOICE, voice = voice_idx}, values, {}, nil,
      {type = capture.type, values = capture.values, preset_name = capture.preset_name})
    request_redraw()
  end

  -- Put back what the held randomize replaced, in the order it set them (a
  -- pair a section draws in order, a loop's start then its length, comes
  -- back whole), through the params' actions (so the LFO offsets, the engine
  -- and the grid follow), and a pattern's old steps through replace_pattern;
  -- the undo ends first. Returns false when nothing is held or its window
  -- has ended. A held voice undo (3.8) applies its capture's type and
  -- values (what a load can change) through S.lib.scenes.apply_voice, every
  -- other scene key of that type (the Out keys) at its present value, with
  -- the voice's present active and source (ruling 46 as amended), and puts
  -- back the name the voice's preset row showed before (#869). 3.9's holds
  -- (#922, #927): a routing first, then the held params (a chain start's
  -- keys, a routing's depth and touched param), the seven whole patterns
  -- (their levels, steps and lane lengths, 2c, through
  -- S.lib.sequencer.replace_whole) and the letters (4a), a sequence's values
  function M.undo()
    local undo = S.undo
    if not undo or util.time() >= undo.until_time then return false end
    clear_undo()
    write_as_undo(function()
      if undo.capture then
        local voice = S.voices[undo.voice]
        local values = {}
        for _, entry in ipairs((S.lib.params_setup.voice_scene_keys(undo.voice, undo.capture.type))) do
          local value = undo.capture.values[entry.key]
          if value == nil then value = voice.values[entry.key] end
          values[entry.key] = value
        end
        S.lib.scenes.apply_voice(undo.voice, {active = voice.active, source = voice.source,
          type = undo.capture.type, values = values})
        S.lib.voice_presets.restore_name(undo.voice, undo.capture.preset_name)
      end
      local routing = undo.routing
      if routing then S.lib.matrix.set_routing(routing.k, routing.source, routing.dest) end
      for _, param_id in ipairs(undo.ids) do set_randomized_param(param_id, undo.values[param_id]) end
      if undo.pattern then
        local pattern = undo.pattern
        S.lib.sequencer.replace_pattern(pattern.voice, pattern.steps)
        for step in ipairs(pattern.steps) do
          S.lib.sequencer.set_step_attr(pattern.voice, step, "va", pattern.values_a[step])
        end
      end
      if undo.patterns then
        for voice_idx = 1, NUM_VOICES do
          S.lib.sequencer.replace_whole(voice_idx, {levels = undo.patterns[voice_idx], steps = undo.steps[voice_idx],
            lanes = undo.lanes[voice_idx]})
        end
        S.lib.pattern_letters.apply_block(undo.letters)
      end
      if undo.sequence then
        for index, value in ipairs(undo.sequence.values) do
          S.lib.random_sequences.set_value(undo.sequence.n, index, value)
        end
      end
    end)
    request_redraw()
    grid_redraw()
    return true
  end

  -- A record group's keys for a voice (S.lib.params_setup.group_keys), or
  -- none when its when says no
  local function shown_keys(group, voice_idx)
    if group.when and not group.when(voice_idx) then return {} end
    return S.lib.params_setup.group_keys(group, voice_idx)
  end

  -- MAIN's whole-voice spec (randomize_voice, MAIN's ALT+K2): every
  -- record's main_randomize groups (the groundwork before 3.8), in
  -- registration order, each key with its group's draw. The built-in
  -- records hold 3.7's sets (lib/voices.lua): for a synth source every
  -- synthesis param but amp, uniform in its controlspec's normalized range
  -- (so exp params, freq and cutoff, spread evenly across octaves), in the
  -- voice's param_order (ruling 9; pairs order before), so the order is
  -- the same on every run and on both Luas; for a buffer source the buffer
  -- params (rate 0.5-2, even in octaves; gentle scan); for the input
  -- neither (they do nothing); then grain size and pitch
  function M.voice_spec(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    local draws = {}
    for _, record in ipairs(S.registry.voice_params) do
      for _, group in ipairs(record.main_randomize or {}) do
        for _, key in ipairs(shown_keys(group, voice_idx)) do
          local param_id = prefix .. key
          draws[#draws + 1] = {id = param_id, draw = function() return group.draw(voice_idx, key, param_id) end}
        end
      end
    end
    return {page = S.constants.UI_PAGES.index.MAIN, section = "voice", voice = voice_idx, draws = draws}
  end

  -- An undo of MAIN's randomize of voice_idx is held and its window has not ended
  function undo_available(voice_idx)
    return M.undo_for(S.constants.UI_PAGES.index.MAIN, "voice", voice_idx)
  end

  -- The held undo, wherever it was made (M.undo). Returns false when there
  -- is nothing to undo
  function undo_randomize()
    return M.undo()
  end

  -- Called by the actions of every param a randomize can set
  -- (lib/params_setup.lua, add_voice_param's for every per-voice param): an
  -- edit of a held param ends the undo, so undo never overwrites it. The
  -- drift's writes and randomize's and undo's own are not edits
  function note_param_edit(param_id)
    if S.drift_writing or undo_writing then return end
    local undo = S.undo
    if not (undo and undo.values[param_id] ~= nil) then return end
    -- a learn's touched param keeps its hold through the turn that learned
    -- going on: the detent path's own set of it (S.lib.ui_detent's mark,
    -- its stop at 0 included), never a set, a grid fader, the PARAMS
    -- menu's turn or a mutation step (#927)
    if undo.routing and undo.routing.param == param_id and S.lib.ui_detent.detent_param() == param_id then
      return
    end
    clear_undo()
  end

  -- Called by every edit of voice_idx's pattern (lib/sequencer.lua): it
  -- ends a pattern undo of that voice, and a chain start's of all seven
  -- (#922). The randomize's and the undo's own writes are not edits
  function M.note_pattern_edit(voice_idx)
    if undo_writing then return end
    local undo = S.undo
    if undo and ((undo.pattern and undo.pattern.voice == voice_idx) or undo.patterns) then clear_undo() end
  end

  -- Called by every write of random sequence n's values but new's and the
  -- drift's (lib/random_sequences.lua: a hand edit, a stored list loaded):
  -- it ends a held new of that sequence (#922)
  function M.note_sequence_edit(n)
    if undo_writing then return end
    if S.undo and S.undo.sequence and S.undo.sequence.n == n then clear_undo() end
  end

  -- Called by every write of matrix routing k's source or destination
  -- (lib/matrix.lua): it ends a held learn of that routing (#927)
  function M.note_routing_edit(k)
    if undo_writing then return end
    if S.undo and S.undo.routing and S.undo.routing.k == k then clear_undo() end
  end

  -- MAIN's whole-voice randomize (M.voice_spec). Returns whether it ran: an
  -- index outside 1..NUM_VOICES or a locked voice is left alone, and so is
  -- an earlier undo
  function randomize_voice(voice_idx)
    if not is_index(voice_idx, NUM_VOICES) then return false end
    return M.randomize(M.voice_spec(voice_idx))
  end

  -- One step of the drift's walk: a random step of width step (+/- step / 2)
  -- plus a pull back toward base, removing reversion of the offset per step
  function mean_reverting_step(current, base, step, reversion)
    return current + ((math.random() - 0.5) * step - (current - base) * reversion)
  end

  -- Set a param as the drift: its action sees S.drift_writing, so the write is
  -- not taken as a new center for the walk. The flag is put back as it was
  -- found, so a write nested in another leaves the outer's set (#892), and
  -- it must not outlive an error in the action (every later edit would be
  -- taken for the drift's): put it back, then raise the error again, with
  -- its traceback
  function set_drifted_param(param_id, value)
    local outer = S.drift_writing
    S.drift_writing = true
    local set, set_error = xpcall(params.set, with_traceback, params, param_id, value)
    S.drift_writing = outer
    if not set then error(set_error, 0) end
  end

  function drift_update()
    -- Slow grain pitch drift for active, unlocked voices: a small random
    -- step plus a pull back toward the last user/scene/mutation-set pitch, so
    -- the walk stays a subtle detune instead of wandering to the rails
    for i = 1, NUM_VOICES do
      if S.voices[i].active and not S.locked[i] then
        local pitch = mean_reverting_step(S.voices[i].values.grain_pitch, S.grain_pitch_base[i],
          DRIFT_PITCH_STEP, DRIFT_PITCH_REVERSION)
        set_drifted_param("v" .. i .. "_grain_pitch", util.clamp(pitch, 0.25, 4))

        -- Buffer sources also drift their position the same way
        if voice_uses_buffer(i) then
          local position = mean_reverting_step(S.voices[i].values.buf_pos, S.buf_pos_base[i],
            DRIFT_BUF_POS_STEP, DRIFT_BUF_POS_REVERSION)
          set_drifted_param("v" .. i .. "_buf_pos", util.clamp(position, 0, 1))
          -- MAIN and the BUFFER arc ring show the selected voice's position only
          if i == S.selected_voice then request_redraw() end
        end
      end
    end

    -- The grids follow every param they show (the grain pitch drifts; the
    -- screen, the arc, MIDI maps and PARAMETERS set the rest): a grid is
    -- redrawn when a fader line or a page signature a pane shows moved
    -- (#324; lib/grid/pane.lua, contained per pane)
    S.lib.grid_faders.follow_faders()

    -- drift_update is the script's 10 Hz tick: also drop keys held into the menu
    forget_keys_held_through_menu()
  end

  -- The value a mutation step lands on: delta (a fraction of the param's
  -- normalized 0-1 range) added to current, clamped to the range
  function mutated_value(spec, current, delta)
    return spec:map(util.clamp(spec:unmap(current) + delta, 0, 1))
  end

  -- Set one of voice_idx's params as a mutation step. A step moves the
  -- param from its stored value: a turn (S.lib.ui_detent.as_turn), so a
  -- quantized freq walks by scale tones (#318). A step that changes a param
  -- of the undo's voice (stored or not) clears the undo
  local function set_mutated_param(voice_idx, param_id, value)
    local before = params:get(param_id)
    S.lib.ui_detent.as_turn(param_id, function() params:set(param_id, value) end)
    if S.undo and S.undo.voice == voice_idx and params:get(param_id) ~= before then clear_undo() end
  end

  local function mutate_voices()
    -- Probability-based parameter mutations
    local probability = params:get("mutation_probability")
    local amount = params:get("mutation_amount")

    for i = 1, NUM_VOICES do
      -- Only mutate active, unlocked voices
      if S.voices[i].active and not S.locked[i] then
        local values = S.voices[i].values
        -- Every record's mutate groups (the groundwork before 3.8), in
        -- registration order. The built-in records hold 3.7's sets
        -- (lib/voices.lua): a synth source its synthesis params but amp and
        -- pan, a buffer source its buffer params instead (input neither),
        -- then grain size, pitch and spread at a fraction of the
        -- probability (chance) and a delta scale; never the source, the
        -- envelope, the mode or crossmod. Each key mutates with
        -- probability x chance; its delta is gaussian-like (two averaged
        -- draws) x amount x scale: across the normalized range for a
        -- warped group (exp params move evenly in octaves), else in the
        -- param's units, clamped to its range
        for _, record in ipairs(S.registry.voice_params) do
          for _, group in ipairs(record.mutate or {}) do
            for _, key in ipairs(shown_keys(group, i)) do
              if math.random() < probability * (group.chance or 1) then
                local param_id = "v" .. i .. "_" .. key
                local spec = params:lookup_param(param_id).controlspec
                local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * (group.scale or 1)
                if group.warped == false then
                  set_mutated_param(i, param_id, util.clamp(values[key] + delta, spec.minval, spec.maxval))
                else
                  set_mutated_param(i, param_id, mutated_value(spec, values[key], delta))
                end
              end
            end
          end
        end
      end
    end

    -- Mutated values are shown on the screen, the arc and the 256 grid's
    -- parameter faders
    request_redraw()
    grid_redraw()
  end

  -- The mutation metro's tick: one mutation step, protected (#517). An
  -- error is printed with its traceback, once per distinct message (a good
  -- step forgets it), through the frame's contained_call
  -- (lib/ui/frame.lua), and the next tick mutates again
  local mutation_errors = {}  -- tick: the error message the tick last printed
  function gentle_mutate()
    S.lib.ui_frame.contained_call(mutation_errors, "tick", "mutation", mutate_voices)
  end

  -- init's start steps: the per-voice drift runs from the start; the
  -- mutation metro waits for the mutation_enabled param to start it
  S.register_start(S.constants.START_ORDER.drift_metro, function()
    S.drift_metro = metro.init()
    S.drift_metro.time = 0.1
    S.drift_metro.event = drift_update
    S.drift_metro:start()
  end)
  S.register_start(S.constants.START_ORDER.mutation_metro, function()
    S.mutation_metro = metro.init()
    S.mutation_metro.time = params:get("mutation_rate")
    S.mutation_metro.event = gentle_mutate
  end)

  -- cleanup()'s steps: stop the drift, then the mutations, setting their
  -- param to off so param and metro agree, then cancel the undo's expiry clock
  -- (S.lib.clocks.cancel: a cleanup step's, at once)
  S.register_cleanup(S.constants.CLEANUP_ORDER.drift_metro, function()
    if S.drift_metro then S.drift_metro:stop() end
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.mutation_metro, function()
    if S.mutation_metro then
      S.mutation_metro:stop()
      params:set("mutation_enabled", 0)
    end
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.undo_clock, function()
    S.lib.clocks.cancel(undo_handle)
    undo_handle, undo_clock = nil, nil
  end)

  return M
end

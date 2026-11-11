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
  local DISCRETE_GRAIN_KEYS = S.constants.DISCRETE_GRAIN_KEYS
  local BUFFER_MUTATION_KEYS = S.constants.BUFFER_MUTATION_KEYS
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
    S.grain_pitch_base[i] = S.voices[i].grain.pitch
    S.buf_pos_base[i] = S.voices[i].grain.buf_pos
  end

  -- Mutation system
  S.mutation_metro = nil

  -- The randomize undo, one for the whole script (#557): S.undo = {page,
  -- section, voice (nil off a voice's page), values = {[param_id] = the
  -- value before the randomize}, ids = the values' ids in the order the
  -- randomize set them, pattern = {voice, steps} (a pattern spec's old steps)
  -- or nil, until_time = util.time() at which it expires}, or nil. undo_clock
  -- wakes at until_time to clear it and ask for a redraw (the ALT hint goes
  -- back without input). undo_writing is true while a randomize or the undo
  -- writes, so note_param_edit and note_pattern_edit do not take their
  -- writes for an edit.
  S.undo = nil
  local undo_clock = nil
  local undo_writing = false

  -- Run writes (a function setting params) as randomize's or undo's. The flag
  -- must not outlive an error in a param action (every later edit would keep
  -- the undo): clear it, then raise the error again, with its traceback
  local function write_as_undo(writes)
    undo_writing = true
    local written, write_error = xpcall(writes, with_traceback)
    undo_writing = false
    if not written then error(write_error, 0) end
  end

  function clear_undo()
    if undo_clock then
      clock.cancel(undo_clock)
      undo_clock = nil
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

  -- Hold the undo of the randomize just made, for UNDO_SECONDS
  local function hold_undo(spec, values, ids, pattern)
    S.undo = {page = spec.page, section = spec.section, voice = spec.voice, values = values, ids = ids,
      pattern = pattern, until_time = util.time() + UNDO_SECONDS}
    undo_clock = clock.run(function()
      clock.sleep(UNDO_SECONDS)
      undo_clock = nil  -- first: clear_undo would cancel this clock
      clear_undo()
    end)
  end

  -- A pattern spec: randomize_pattern(voice), its old steps held
  local function randomize_pattern_spec(spec)
    local voice_idx = spec.pattern
    local steps = {}
    for step, level in ipairs(S.patterns[voice_idx]) do steps[step] = level end
    clear_undo()
    write_as_undo(function() randomize_pattern(voice_idx) end)
    hold_undo(spec, {}, {}, {voice = voice_idx, steps = steps})
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
    if spec.voice ~= nil and S.frozen[spec.voice] then return false end
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
  -- (nil off a voice's page) would undo: the undo held is that one's and its
  -- window has not ended
  function M.undo_for(page, section, voice)
    local undo = S.undo
    return undo ~= nil and undo.page == page and undo.section == section and undo.voice == voice
      and util.time() < undo.until_time
  end

  -- Put back what the held randomize replaced, in the order it set them (a
  -- pair a section draws in order, a loop's start then its length, comes
  -- back whole), through the params' actions (so the LFO offsets, the engine
  -- and the grid follow), and a pattern's old steps through replace_pattern;
  -- the undo ends first. Returns false when nothing is held or its window
  -- has ended
  function M.undo()
    local undo = S.undo
    if not undo or util.time() >= undo.until_time then return false end
    clear_undo()
    write_as_undo(function()
      for _, param_id in ipairs(undo.ids) do set_randomized_param(param_id, undo.values[param_id]) end
      if undo.pattern then S.lib.sequencer.replace_pattern(undo.pattern.voice, undo.pattern.steps) end
    end)
    request_redraw()
    grid_redraw()
    return true
  end

  -- MAIN's whole-voice spec (randomize_voice, MAIN's ALT+K2): for a synth
  -- source every synthesis param but amp, uniform in its controlspec's
  -- normalized range (so exp params, freq and cutoff, spread evenly across
  -- octaves); for a buffer source the buffer params (rate 0.5-2, even in
  -- octaves; gentle scan); for the input neither (they do nothing); then
  -- grain size and pitch. The draws keep randomize_voice's order, so a
  -- seeded randomize lands where it always did
  function M.voice_spec(voice_idx)
    local prefix = "v" .. voice_idx .. "_"
    local draws = {}
    local function add(key, draw) draws[#draws + 1] = {id = prefix .. key, draw = draw} end
    if voice_uses_synth(voice_idx) then
      for key in pairs(S.voices[voice_idx].params) do
        if key ~= "amp" then  -- never the level
          add(key, function() return params:lookup_param(prefix .. key).controlspec:map(math.random()) end)
        end
      end
    elseif voice_uses_buffer(voice_idx) then
      add("buf_pos", function() return math.random() end)
      add("buf_rate", function() return 2 ^ (math.random() * 2 - 1) end)
      add("buf_scan", function() return math.random() - 0.5 end)
    end
    add("grain_size", function() return math.random() * 0.3 + 0.05 end)
    add("grain_pitch", function() return math.random() * 2 + 0.5 end)
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
  -- (lib/params_setup.lua, add_voice_extra's for the registered params): an
  -- edit of a held param ends the undo, so undo never overwrites it. The
  -- drift's writes and randomize's and undo's own are not edits
  function note_param_edit(param_id)
    if S.drift_writing or undo_writing then return end
    if S.undo and S.undo.values[param_id] ~= nil then clear_undo() end
  end

  -- Called by every edit of voice_idx's pattern (lib/sequencer.lua): it
  -- ends a pattern undo of that voice. The randomize's and the undo's own
  -- writes are not edits
  function M.note_pattern_edit(voice_idx)
    if undo_writing then return end
    if S.undo and S.undo.pattern and S.undo.pattern.voice == voice_idx then clear_undo() end
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
  -- not taken as a new center for the walk. The flag must not outlive an
  -- error in the action (every later edit would be taken for the drift's):
  -- clear it, then raise the error again, with its traceback
  function set_drifted_param(param_id, value)
    S.drift_writing = true
    local set, set_error = xpcall(params.set, with_traceback, params, param_id, value)
    S.drift_writing = false
    if not set then error(set_error, 0) end
  end

  function drift_update()
    -- Slow grain pitch drift for active, non-frozen voices: a small random
    -- step plus a pull back toward the last user/scene/mutation-set pitch, so
    -- the walk stays a subtle detune instead of wandering to the rails
    for i = 1, NUM_VOICES do
      if S.voices[i].active and not S.frozen[i] then
        local pitch = mean_reverting_step(S.voices[i].grain.pitch, S.grain_pitch_base[i],
          DRIFT_PITCH_STEP, DRIFT_PITCH_REVERSION)
        set_drifted_param("v" .. i .. "_grain_pitch", util.clamp(pitch, 0.25, 4))

        -- Buffer sources also drift their position the same way
        if voice_uses_buffer(i) then
          local position = mean_reverting_step(S.voices[i].grain.buf_pos, S.buf_pos_base[i],
            DRIFT_BUF_POS_STEP, DRIFT_BUF_POS_REVERSION)
          set_drifted_param("v" .. i .. "_buf_pos", util.clamp(position, 0, 1))
          -- MAIN and the BUFFER arc ring show the selected voice's position only
          if i == S.selected_voice then request_redraw() end
        end
      end
    end

    -- The faders pages follow every param they show (the grain pitch
    -- drifts; the screen, the arc, MIDI maps and PARAMETERS set the rest):
    -- a grid on page 2 is redrawn when a shown fader moved (#324)
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
      -- Only mutate active, non-frozen voices
      if S.voices[i].active and not S.frozen[i] then
        local v = S.voices[i]

        if voice_uses_synth(i) then
          -- Iterate through synthesis parameters
          for key, current_val in pairs(v.params) do
            -- Skip amplitude and pan to preserve stability
            if key ~= "amp" and key ~= "pan" then
              -- Check if this parameter should mutate
              if math.random() < probability then
                local spec = params:lookup_param("v" .. i .. "_" .. key).controlspec

                -- Mutation delta as a fraction of the normalized range, so exp
                -- params move evenly in octaves. Gaussian-like distribution by
                -- averaging random values
                local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount
                set_mutated_param(i, "v" .. i .. "_" .. key, mutated_value(spec, current_val, delta))
              end
            end
          end
        elseif voice_uses_buffer(i) then
          -- Buffer sources mutate their buffer params instead of the (silent)
          -- synthesis params. Input sources mutate only the grain params
          -- below. The source itself never mutates.
          for _, key in ipairs(BUFFER_MUTATION_KEYS) do
            if not DISCRETE_GRAIN_KEYS[key] and math.random() < probability then
              local param_id = "v" .. i .. "_" .. key
              local spec = params:lookup_param(param_id).controlspec
              -- delta across the normalized range, so exp buf_rate moves evenly
              local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount
              set_mutated_param(i, param_id, mutated_value(spec, v.grain[key], delta))
            end
          end
        end

        -- Occasionally mutate granular parameters (lower probability: a
        -- fraction of it, and a delta scale, per key). The discrete ones
        -- (DISCRETE_GRAIN_KEYS: envelope shape, grain mode) never mutate.
        for _, mutation in ipairs({
          {key = "size", param = "grain_size", chance = 0.5, scale = 0.2},
          {key = "pitch", param = "grain_pitch", chance = 0.3, scale = 1.0},
          {key = "spread", param = "grain_spread", chance = 0.2, scale = 0.3}
        }) do
          if not DISCRETE_GRAIN_KEYS[mutation.key] and math.random() < probability * mutation.chance then
            local param_id = "v" .. i .. "_" .. mutation.param
            local spec = params:lookup_param(param_id).controlspec
            local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount * mutation.scale
            set_mutated_param(i, param_id, util.clamp(v.grain[mutation.key] + delta, spec.minval, spec.maxval))
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
    if undo_clock then
      clock.cancel(undo_clock)
      undo_clock = nil
    end
  end)

  return M
end

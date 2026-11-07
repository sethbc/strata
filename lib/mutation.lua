-- lib/mutation.lua
-- Per-voice drift (drift_update, on the 10 Hz S.drift_metro: a slow random
-- walk of grain pitch and buffer position; not the global LFOs), randomize
-- (randomize_voice, with one level of undo: S.undo, undo_randomize) and
-- mutations (gentle_mutate, on S.mutation_metro).
-- The functions stay global. The metros are created by init in strata.lua;
-- this module registers their cleanup steps.
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

  -- Randomize undo, one level: S.undo = {voice = i, values = {[param_id] =
  -- the value before the randomize}, until_time = util.time() at which it
  -- expires}, or nil. undo_clock wakes at until_time to clear it and ask for
  -- a redraw (MAIN's ALT hint goes back without input). undo_writing is true
  -- while randomize_voice or undo_randomize sets params, so note_param_edit
  -- does not take their writes for a manual edit.
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

  -- An undo for voice_idx is held and its window has not ended
  function undo_available(voice_idx)
    return S.undo ~= nil and S.undo.voice == voice_idx and util.time() < S.undo.until_time
  end

  -- Put back the values the last randomize replaced, through params:set (so
  -- the LFO offsets, the engine and the grid follow), and clear the undo.
  -- Returns false when there is nothing to undo
  function undo_randomize()
    local undo = S.undo
    if not undo or not undo_available(undo.voice) then return false end
    clear_undo()
    local ids = {}
    for param_id in pairs(undo.values) do ids[#ids + 1] = param_id end
    table.sort(ids)
    write_as_undo(function()
      for _, param_id in ipairs(ids) do params:set(param_id, undo.values[param_id]) end
    end)
    request_redraw()
    grid_redraw()
    return true
  end

  -- Called by the voice param actions randomize can set (lib/params_setup.lua):
  -- an edit of a stored param clears the undo, so undo never overwrites it.
  -- The drift's writes and randomize's and undo's own are not edits
  function note_param_edit(param_id)
    if S.drift_writing or undo_writing then return end
    if S.undo and S.undo.values[param_id] ~= nil then clear_undo() end
  end

  function randomize_voice(voice_idx)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    -- a locked voice is left alone, and so is an earlier undo
    if S.frozen[voice_idx] then return end

    local voice = S.voices[voice_idx]
    local prefix = "v" .. voice_idx .. "_"
    local previous = {}
    local function randomize_param(param_id, value)
      previous[param_id] = params:get(param_id)
      params:set(param_id, value)
    end

    -- one level: this randomize replaces any earlier undo, another voice's too
    clear_undo()
    write_as_undo(function()
      if voice_uses_synth(voice_idx) then
        -- Randomize synth params
        for key, _ in pairs(voice.params) do
          if key ~= "amp" then -- Don't randomize amplitude
            local spec = get_param_spec(key)
            -- uniform in the normalized 0-1 range, so exp params (freq, cutoff)
            -- spread evenly across octaves instead of piling up at the top
            randomize_param(prefix .. key, spec:map(math.random()))
          end
        end
      elseif voice_uses_buffer(voice_idx) then
        -- Buffer source: the synth is not playing, so randomize the buffer
        -- params instead (rate 0.5-2, even in octaves; gentle scan)
        randomize_param(prefix .. "buf_pos", math.random())
        randomize_param(prefix .. "buf_rate", 2 ^ (math.random() * 2 - 1))
        randomize_param(prefix .. "buf_scan", math.random() - 0.5)
      end
      -- (input source: neither synth nor buffer params do anything; only the
      -- grain params below are randomized)

      -- Randomize some grain params
      randomize_param(prefix .. "grain_size", math.random() * 0.3 + 0.05)
      randomize_param(prefix .. "grain_pitch", math.random() * 2 + 0.5)
    end)

    S.undo = {voice = voice_idx, values = previous, until_time = util.time() + UNDO_SECONDS}
    undo_clock = clock.run(function()
      clock.sleep(UNDO_SECONDS)
      undo_clock = nil  -- first: clear_undo would cancel this clock
      clear_undo()
    end)

    request_redraw()
    grid_redraw()
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

    -- Grain pitch is shown on the parameter fader page; this runs 10x/s, so
    -- only redraw when a grid is actually showing that page
    if next(S.grids) ~= nil and S.grid_page == 2 then
      grid_redraw()
    end

    -- drift_update is the script's 10 Hz tick: also drop keys held into the menu
    forget_keys_held_through_menu()
  end

  -- The value a mutation step lands on: delta (a fraction of the param's
  -- normalized 0-1 range) added to current, clamped to the range
  function mutated_value(spec, current, delta)
    return spec:map(util.clamp(spec:unmap(current) + delta, 0, 1))
  end

  -- Set one of voice_idx's params as a mutation step. A step that changes a
  -- param of the undo's voice (stored or not) clears the undo
  local function set_mutated_param(voice_idx, param_id, value)
    local before = params:get(param_id)
    params:set(param_id, value)
    if S.undo and S.undo.voice == voice_idx and params:get(param_id) ~= before then clear_undo() end
  end

  function gentle_mutate()
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
                local spec = get_param_spec(key)

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

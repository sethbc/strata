-- lib/mutation.lua
-- Per-voice drift (drift_update, on the 10 Hz S.drift_metro: a slow random
-- walk of grain pitch and buffer position; not the global LFOs), randomize
-- (randomize_voice) and mutations (gentle_mutate, on S.mutation_metro).
-- The functions stay global. The metros are created by init in strata.lua.
-- S.grain_pitch_base and S.buf_pos_base (the walk's centers) are also set by
-- the grain pitch and buffer position param actions, so they live on S, as
-- does S.drift_writing, which those actions and redraw_on_param_changes read.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local DISCRETE_GRAIN_KEYS = S.constants.DISCRETE_GRAIN_KEYS
  local BUFFER_MUTATION_KEYS = S.constants.BUFFER_MUTATION_KEYS

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

  function randomize_voice(voice_idx)
    if S.frozen[voice_idx] then return end
    
    local voice = S.voices[voice_idx]
    local prefix = "v" .. voice_idx .. "_"

    if voice_uses_synth(voice_idx) then
      -- Randomize synth params
      for key, _ in pairs(voice.params) do
        if key ~= "amp" then -- Don't randomize amplitude
          local spec = get_param_spec(key)
          -- uniform in the normalized 0-1 range, so exp params (freq, cutoff)
          -- spread evenly across octaves instead of piling up at the top
          params:set(prefix .. key, spec:map(math.random()))
        end
      end
    elseif voice_uses_buffer(voice_idx) then
      -- Buffer source: the synth is not playing, so randomize the buffer
      -- params instead (rate 0.5-2, even in octaves; gentle scan)
      params:set(prefix .. "buf_pos", math.random())
      params:set(prefix .. "buf_rate", 2 ^ (math.random() * 2 - 1))
      params:set(prefix .. "buf_scan", math.random() - 0.5)
    end
    -- (input source: neither synth nor buffer params do anything; only the
    -- grain params below are randomized)
    
    -- Randomize some grain params
    params:set("v" .. voice_idx .. "_grain_size", math.random() * 0.3 + 0.05)
    params:set("v" .. voice_idx .. "_grain_pitch", math.random() * 2 + 0.5)
    
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
                params:set("v" .. i .. "_" .. key, mutated_value(spec, current_val, delta))
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
              params:set(param_id, mutated_value(spec, v.grain[key], delta))
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
            params:set(param_id, util.clamp(v.grain[mutation.key] + delta, spec.minval, spec.maxval))
          end
        end
      end
    end

    -- Mutated values are shown on the screen, the arc and the 256 grid's
    -- parameter faders
    request_redraw()
    grid_redraw()
  end

  return M
end

## Must not break

- Never mutate `amp` or `pan`, the discrete grain keys (`DISCRETE_GRAIN_KEYS`: envelope shape and grain mode), the voice's `source`, or the crossmod sources and amounts. `randomize_voice` never touches `amp`.
- Every grain key `gentle_mutate` changes is guarded by `not DISCRETE_GRAIN_KEYS[key]`, checked before the `math.random()` draw, so the random sequence stays the same.
- Frozen voices are left alone: no drift, no mutation, and `randomize_voice` returns for them (buffer params included).
- Randomize and mutate synth and buffer params in the controlspec's normalized 0-1 range (`spec:map`, `mutated_value`), so exponential params move evenly in octaves.
- The drift writes only through `set_drifted_param`, which sets `S.drift_writing` around each write inside an `xpcall`, so the flag always clears and an error is raised again with its traceback.
- `mean_reverting_step` draws exactly one `math.random()` per call.
- Cleanup stops the mutation metro and sets `mutation_enabled` to 0, so param and state agree.

## Owns

`lib/mutation.lua` (`S.lib.mutation`):
- the per-voice drift: `drift_update`, `mean_reverting_step`, `set_drifted_param` (`S.drift_metro`);
- `randomize_voice`, `gentle_mutate` (`S.mutation_metro`), `mutated_value`;
- `S.drift_writing`, `S.grain_pitch_base` and `S.buf_pos_base`, on `S` because the grain pitch and buffer position param actions read them;
- cleanup steps 70 (drift metro) and 80 (mutation metro).

Elsewhere:
- Its start steps (`START_ORDER.drift_metro`, `mutation_metro`) create `S.drift_metro` and `S.mutation_metro` at init.
- `drift_update` reads `S.grids` and `S.grid_page` (`lib/grid/core.lua`).
- `DISCRETE_GRAIN_KEYS` and `BUFFER_MUTATION_KEYS` are in `lib/constants.lua`, aliased at the top of the constructor.
- The mutation params are the "mutations" record of `lib/params_setup.lua`.

## Mutations

Parts:
- **Mutation metro**: `S.mutation_metro` periodically calls `gentle_mutate()`.
- **`gentle_mutate()`**: applies probability-based parameter changes.
- **Params** (PARAMS menu):
  - `mutation_enabled` (0/1): mutations on or off;
  - `mutation_rate` (0.5-10 s): how often mutations are checked;
  - `mutation_probability` (0-1): chance each parameter mutates per check;
  - `mutation_amount` (0-1): size of the delta relative to the parameter's range.

Normalized space:
- Synth and buffer params mutate by a delta in the controlspec's normalized 0-1 range: `mutated_value(spec, current, delta)` unmaps, adds, clamps and maps.
- `randomize_voice` draws synth params with `spec:map(math.random())`.
- Exponential params (freq, cutoff, buf_rate) therefore move evenly in octaves.
- Grain size, pitch and spread are linear, so their absolute deltas and ranges are unchanged.
- The Lua drifts (grain pitch, buffer position) act on linear params. The engine's tape drift is separate.

`gentle_mutate()` (`lib/mutation.lua`), in outline:

```lua
function gentle_mutate()
  local probability = params:get("mutation_probability")
  local amount = params:get("mutation_amount")

  for i = 1, NUM_VOICES do
    if S.voices[i].active and not S.frozen[i] then
      -- synth source: each synthesis parameter
      for key, current_val in pairs(S.voices[i].params) do
        if key ~= "amp" and key ~= "pan" then
          if math.random() < probability then
            -- Gaussian-like delta as a fraction of the normalized 0-1 range
            local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount
            params:set("v" .. i .. "_" .. key, mutated_value(spec, current_val, delta))
          end
        end
      end

      -- Granular parameters mutate at lower probabilities
      -- grain_size: 0.5× probability
      -- grain_pitch: 0.3× probability
      -- grain_spread: 0.2× probability
    end
  end
end
```

Design decisions:
- **Excluded params**: `amp` and `pan` keep the voice's balance and stereo placement. The discrete grain keys and the source never mutate either.
- **Buffer and input sources**:
  - a buffer-sourced voice mutates `BUFFER_MUTATION_KEYS` (`buf_pos`, `buf_rate`, `buf_scan`, each with `probability`; delta = gaussian × `amount` in the controlspec's normalized range, so the exp `buf_rate` moves evenly) instead of its synthesis params;
  - an input-sourced voice mutates neither synthesis nor buffer params;
  - grain size, pitch and spread mutate as for every voice.
- **Frozen voices** are excluded.
- **Gaussian distribution**: averaging two random values gives a bell curve, favoring small changes.
- **Relative deltas**: the amount is a fraction of the controlspec's normalized range, so behavior is the same across specs.
- **Granular hierarchy**: grain parameters mutate less often than synthesis parameters.

Usage:

```lua
params:set("mutation_enabled", 1)
params:set("mutation_probability", 0.15)  -- 15% chance per parameter
params:set("mutation_amount", 0.25)       -- 25% of parameter range
params:set("mutation_rate", 2)            -- check every 2 seconds
```

Recommended settings:
- **Subtle evolution**: probability 0.1, amount 0.15, rate 3 s.
- **Moderate change**: probability 0.15, amount 0.25, rate 2 s (default).
- **Dramatic shift**: probability 0.25, amount 0.4, rate 1 s.

Lifecycle:
- **Initialization**: its start step creates the metro at init but does not start it.
- **Control**: the `mutation_enabled` action starts and stops the metro.
- **Cleanup**: step 80 stops it (and sets `mutation_enabled` to 0), so no timer is left behind.

## Drift and the other systems

- **Drift**: mutations run alongside `drift_update()` (the per-voice drift, not the global LFOs). It gives each active, unfrozen voice a subtle mean-reverting grain pitch drift:
  - `mean_reverting_step(current, base, DRIFT_PITCH_STEP, DRIFT_PITCH_REVERSION)` = `current + ((math.random() - 0.5) * step - (current - base) * reversion)`;
  - step 0.004, reversion 0.01 per 100 ms tick; one `math.random()` per call.
  - `base` (`S.grain_pitch_base[i]`) is the last grain pitch set by anything other than the drift (user, mutation, scene). The param action tracks it through the `S.drift_writing` flag, which the drift sets around each write in `set_drifted_param` (an `xpcall` with `with_traceback`: an error in the param action clears the flag and is raised again with its traceback).
  - The `grain_pitch` controlspec has step 0, so these small steps are not quantized away.
  - Buffer-sourced voices also drift `buf_pos` with the same helper (`DRIFT_BUF_POS_STEP` 0.002, `DRIFT_BUF_POS_REVERSION` 0.01, center `S.buf_pos_base[i]`, `buf_pos` step 0).
- **Freeze**: frozen voices are stable. Neither the drift nor mutations affect them (buffer params included), and `randomize_voice` returns for a frozen voice.
- **Cross-modulation**: mutations never touch the crossmod sources or amounts. The routing a voice has (set by hand or by a scene) keeps modulating the mutated params.
- **UI feedback**: `[M]` appears in the header (x=98) while mutations are on.

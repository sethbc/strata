## Must not break

- Never mutate `amp` or `pan`, the discrete grain keys (`DISCRETE_GRAIN_KEYS`: envelope shape and grain mode), the voice's `source`, or the crossmod sources and amounts. `randomize_voice` never touches `amp`.
- Every grain key `gentle_mutate` changes is guarded by `not DISCRETE_GRAIN_KEYS[key]`, checked before the `math.random()` draw, so the random sequence stays the same.
- Frozen voices are left alone: no drift, no mutation, and `randomize_voice` returns for them (buffer params included). Stopped voices are too: the drift and mutations touch only running voices (`S.voices[i].active`).
- A mutation step is a turn (#318): `set_mutated_param` sets the param inside `S.lib.ui_detent.as_turn`, so a quantized `freq` walks by scale tones however small each step is (as a set, a step under half a scale step would snap back to its tone; `docs/notes/lua/variation.md`).
- While a grid shows page 2 (the 256's faders), each drift tick redraws it: that tick is what brings an E3, MIDI or PARAMS edit to the faders.
- Randomize and mutate synth and buffer params in the controlspec's normalized 0-1 range (`spec:map`, `mutated_value`), so exponential params move evenly in octaves.
- The drift writes only through `set_drifted_param`, which sets `S.drift_writing` around each write inside an `xpcall`, so the flag always clears and an error is raised again with its traceback.
- `mean_reverting_step` draws exactly one `math.random()` per call.
- Cleanup stops the mutation metro and sets `mutation_enabled` to 0, so param and state agree.
- `gentle_mutate` (the mutation metro's event) never raises (#517): it runs the step (`mutate_voices`) through the frame's `S.lib.ui_frame.contained_call`, which prints `strata: mutation failed:` with the traceback, once per distinct message (a good step forgets it), so the next tick mutates again.
- Every randomize goes through `S.lib.mutation.randomize(spec)` (#557): MAIN's `randomize_voice` is `randomize(voice_spec(i))`, and every other page hands it its section's spec. It stores the previous value of every param a spec draws, and only those. A param a spec starts drawing needs a `note_param_edit(param_id)` call in its action (`lib/params_setup.lua`, `add_voice_extra` for the registered params), or a manual edit would be overwritten by an undo; a test sets every drawn id of every page record's `randomize_section`, in each of its layout states and, on VOICE, with the cursor on the first row of each section of a synth voice and of a buffer voice (placed through `S.lib.pages_voice.place_cursor`), and requires the call. Each case runs on a fresh load and takes its layout state from that load's own record: a state's setup acts on the script it was built in.
- `voice_spec(i)` keeps `randomize_voice`'s draws in their order (pairs order of the synth params, then the buffer params, then grain size and pitch), each `draw()` called just before its set, so a seeded randomize lands where it did before #557.
- There is one undo for the whole script, `S.undo`, cleared by: a randomize (of any page, section or voice: a new one replaces it), a scene recall (`recall_scene` and `recall_scene_instant`), a `gentle_mutate` step that changes a param of the undo's voice (`set_mutated_param`), an edit of a stored param (`note_param_edit`), an edit of a pattern undo's voice's pattern (`S.lib.mutation.note_pattern_edit`) and the end of the window (`undo_clock`). The drift's writes (`S.drift_writing`) and randomize's and undo's own (`undo_writing`) never clear it.
- A quick ALT+K2 undoes only where the undo was made: `undo_for(page, section, voice)` is true for the undo's own page, section and voice within `UNDO_SECONDS`, so a press on another page or section randomizes there (and replaces the undo).
- A binary param a spec draws, and its restore, go through `set_binary_param`, so a controller mapped to it follows (#538).
- `undo_writing` is set around the writes inside an `xpcall` (`write_as_undo`), so the flag always clears and an error is raised again with its traceback.
- A draws spec of a locked voice (`S.frozen[spec.voice]`), or one with no draws, returns false before anything is drawn, stored or cleared. A locked voice can still be edited. A pattern spec randomizes a locked voice's pattern, as SEQ always has: the lock covers params, not patterns.
- Every `clear_undo` cancels `undo_clock`; the clock sets `undo_clock` to nil before it clears the undo, so it never cancels itself.

## Owns

`lib/mutation.lua` (`S.lib.mutation`):
- the per-voice drift: `drift_update`, `mean_reverting_step`, `set_drifted_param` (`S.drift_metro`);
- every page's randomize: `S.lib.mutation.randomize(spec)`, `S.lib.mutation.voice_spec(i)` (MAIN's spec) and `randomize_voice`; `gentle_mutate` (`S.mutation_metro`), `mutated_value`;
- the randomize undo: `S.undo`, `S.lib.mutation.undo_for`, `S.lib.mutation.undo`, `S.lib.mutation.note_pattern_edit`, the globals `undo_available`, `undo_randomize`, `clear_undo`, `note_param_edit`, and the locals `undo_clock`, `undo_writing`, `write_as_undo`, `set_randomized_param`, `check_spec`, `hold_undo`, `set_mutated_param`;
- `S.drift_writing`, `S.grain_pitch_base` and `S.buf_pos_base`, on `S` because the grain pitch and buffer position param actions read them;
- cleanup steps 70 (drift metro), 80 (mutation metro) and 85 (the undo's expiry clock).

Elsewhere:
- Its start steps (`START_ORDER.drift_metro`, `mutation_metro`) create `S.drift_metro` and `S.mutation_metro` at init.
- `drift_update` calls `S.lib.grid_faders.follow_faders()` (`lib/grid/faders.lua`), which redraws the grids while one shows page 2 only when a fader shown there moved, whoever moved it (#324).
- `DISCRETE_GRAIN_KEYS`, `BUFFER_MUTATION_KEYS` and `UNDO_SECONDS` are in `lib/constants.lua`, aliased at the top of the constructor.
- The actions of the params a randomize sets call `note_param_edit` (`lib/params_setup.lua`); `recall_scene` and `recall_scene_instant` call `clear_undo` (`lib/scenes.lua`).
- The ALT+K2 that calls `randomize` and `undo`, and its hint, are the shared handler's (`S.lib.ui_alt.k2_down`, `k2_up`, `k2_hint`, `docs/notes/lua/ui/alt-and-keys.md`); each page's spec is its record's `randomize_section` (MAIN's: `docs/notes/lua/pages/main.md`).
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

## Randomize and its undo

One randomize for every page and one undo for the whole script, for `UNDO_SECONDS` (5 s, `lib/constants.lua`; #557):
- **The spec** a page hands `S.lib.mutation.randomize(spec)` is one of:
  - `{page = <UI_PAGES index>, section = <string>, voice = <1..NUM_VOICES or nil>, draws = {{id = <param id>, draw = fn() -> value}, ...}}`: each draw in order, `draw()` called just before its set, so a later draw may read an earlier one's new value;
  - `{page, section, voice, pattern = <voice index>}`: that voice's pattern, through `randomize_pattern(voice)`, its old steps held.
  A malformed spec (no page or section, a voice or pattern out of range, a draw without a param id or a function) raises: it is a bug in its page.
- **`randomize(spec)`** returns false, changing nothing (an earlier undo stays), for a draws spec of a locked voice or with no draws. Otherwise it clears any undo, sets each draw through `set_randomized_param` (`params:set`, or `set_binary_param` for a binary param) inside `write_as_undo`, after storing every drawn param's previous `params:get` value before the first set (a set's action may change a later drawn param: a loop start's cuts its length, so the length's value at its own turn is not the one to restore), and holds `S.undo = {page, section, voice, values = {[param_id] = value}, ids = {param_id, ...} (in the order set), pattern = {voice, steps} or nil, until_time = util.time() + UNDO_SECONDS}`; it starts `undo_clock`, requests a redraw, redraws the grids and returns true.
- **`voice_spec(i)`** is MAIN's whole-voice spec, `{page = MAIN, section = "voice", voice = i, draws}`: synth params but `amp` (`spec:map(math.random())`) for a synth source, `buf_pos` (r), `buf_rate` (`2 ^ (2r - 1)`) and `buf_scan` (r - 0.5) for a buffer source, nothing more for input; then `grain_size` (0.3r + 0.05) and `grain_pitch` (2r + 0.5). The draws are the same, in the same order, as before #557. `randomize_voice(i)` is `randomize(voice_spec(i))`, returning false at once for an index outside 1..`NUM_VOICES`.
- **`undo_for(page, section, voice)`**: `S.undo` is that page's, section's and voice's (`nil` matches `nil`) and `util.time() < until_time`. `undo_available(i)` is `undo_for(MAIN, "voice", i)`, MAIN's undo of voice `i`.
- **`undo()`** (and the global `undo_randomize()`): false when nothing is held or its window has ended; otherwise it clears the undo, then puts every stored value back through `set_randomized_param`, in the order the randomize set them (so a pair a section draws in order, a loop's start then its length, comes back whole), so the LFO offsets, the engine and the grid follow, and a pattern's old steps through `S.lib.sequencer.replace_pattern`, and returns true. The grain pitch and buffer position actions take the restored values as the drift's new centers.
- `clear_undo()` cancels the expiry clock, drops `S.undo` and requests a redraw.
- `undo_clock` sleeps `UNDO_SECONDS` and clears the undo, which requests the redraw that puts the ALT hint back without input. Cleanup step 85 cancels it.
- `note_param_edit(param_id)` is called from the actions of every param a randomize sets. It clears the undo when `param_id` is stored, unless the drift (`S.drift_writing`) or randomize/undo (`undo_writing`) is writing. PARAMS edits, MIDI CC maps, pset loads, grid faders and arc rings all arrive through those actions.
- `S.lib.mutation.note_pattern_edit(voice)` clears a pattern undo of that voice, unless randomize/undo is writing. Only a pattern spec holds a pattern undo, and SEQ is the page that hands one in (#557): every pattern edit calls this (`lib/sequencer.lua`'s `toggle_pattern_step` and `replace_pattern`, which a clear goes through, SEQ's E3 step level, the arc's SEQ rings and the grid's step-level keys).
- `gentle_mutate` writes through `set_mutated_param(voice_idx, param_id, value)`, which marks the step a turn of the param (`S.lib.ui_detent.as_turn`, #318) and clears the undo when the step changed a param of the undo's voice, stored or not (grain spread too).
- A scene recall clears it: `recall_scene` (after validation, before a fade starts) and `recall_scene_instant` (so a fade's end does too).

## Drift and the other systems

- **Drift**: mutations run alongside `drift_update()` (the per-voice drift, not the global LFOs). It gives each active, unfrozen voice a subtle mean-reverting grain pitch drift:
  - `mean_reverting_step(current, base, DRIFT_PITCH_STEP, DRIFT_PITCH_REVERSION)` = `current + ((math.random() - 0.5) * step - (current - base) * reversion)`;
  - step 0.004, reversion 0.01 per 100 ms tick; one `math.random()` per call.
  - `base` (`S.grain_pitch_base[i]`) is the last grain pitch set by anything other than the drift (user, mutation, scene). The param action tracks it through the `S.drift_writing` flag, which the drift sets around each write in `set_drifted_param` (an `xpcall` with `with_traceback`: an error in the param action clears the flag and is raised again with its traceback).
  - The `grain_pitch` controlspec has step 0, so these small steps are not quantized away.
  - Buffer-sourced voices also drift `buf_pos` with the same helper (`DRIFT_BUF_POS_STEP` 0.002, `DRIFT_BUF_POS_REVERSION` 0.01, center `S.buf_pos_base[i]`, `buf_pos` step 0).
- **Lock** (stored as `frozen`): locked voices are stable. Neither the drift nor mutations affect them (buffer params included), and `randomize_voice` returns for a frozen voice.
- **Cross-modulation**: mutations never touch the crossmod sources or amounts. The routing a voice has (set by hand or by a scene) keeps modulating the mutated params.
- **UI feedback**: `[M]` appears in the header (x=76) while mutations are on.

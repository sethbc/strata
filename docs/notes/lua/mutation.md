## Must not break

- **MAIN's randomize and the mutations draw only what the voice-param records' `main_randomize` and `mutate` groups name** (the groundwork before 3.8; `docs/notes/lua/params.md`): `voice_spec` and `mutate_voices` walk every record's groups in registration order, each group whose `when` holds for the voice. The built-in records (`lib/voices.lua`) hold 3.7's sets, so never mutate `amp` or `pan`, the grain mode, the voice's `source`, or the crossmod sources and amounts, and `randomize_voice` never touches `amp`. No module record has either group.
- A key draws its `math.random()` for the probability check only when its group names it for the voice, so the random sequence stays 3.7's for the same keys.
- Frozen voices are left alone: no drift, no mutation, and `randomize_voice` returns for them (buffer params included). Stopped voices are too: the drift and mutations touch only running voices (`S.voices[i].active`).
- A mutation step is a turn (#318): `set_mutated_param` sets the param inside `S.lib.ui_detent.as_turn`, so a quantized `freq` walks by scale tones however small each step is (as a set, a step under half a scale step would snap back to its tone; `docs/notes/lua/variation.md`).
- While a grid shows page 2 (the 256's faders), each drift tick redraws it: that tick is what brings an E3, MIDI or PARAMS edit to the faders.
- Randomize and mutate synth and buffer params in the controlspec's normalized 0-1 range (`spec:map`, `mutated_value`), so exponential params move evenly in octaves.
- The drift writes only through `set_drifted_param`, which sets `S.drift_writing` around each write inside an `xpcall` and then puts back the value it found (#892), so a write nested in another leaves the outer's flag set, the flag never outlives the outermost write, and an error is raised again with its traceback.
- `mean_reverting_step` draws exactly one `math.random()` per call.
- Cleanup stops the mutation metro and sets `mutation_enabled` to 0, so param and state agree.
- `gentle_mutate` (the mutation metro's event) never raises (#517): it runs the step (`mutate_voices`) through the frame's `S.lib.ui_frame.contained_call`, which prints `strata: mutation failed:` with the traceback, once per distinct message (a good step forgets it), so the next tick mutates again.
- Every randomize goes through `S.lib.mutation.randomize(spec)` (#557): MAIN's `randomize_voice` is `randomize(voice_spec(i))`, and every other page hands it its section's spec. It stores the previous value of every param a spec draws, and only those. A param a spec starts drawing needs a `note_param_edit(param_id)` call in its action (`lib/params_setup.lua`, `add_voice_param` for every per-voice param), or a manual edit would be overwritten by an undo; a test sets every drawn id of every page record's `randomize_section`, in each of its layout states and, on VOICE, with the cursor on the first row of each section of a synth voice and of a buffer voice (placed through `S.lib.pages_voice.place_cursor`), and requires the call. Each case runs on a fresh load and takes its layout state from that load's own record: a state's setup acts on the script it was built in. The one randomize outside it: the 256's pattern keys (row 15, columns 9-15, `docs/notes/lua/grid/layout_256.md`) still call `randomize_pattern` directly and hold no undo.
- `voice_spec(i)` draws in one fixed order (the records' and their groups'): the synth params in the voice's `param_order` (but `amp`), then the buffer params, then grain size and pitch, each `draw()` called just before its set, so the order is the same on every run and on Lua 5.3 and LuaJIT, and a seeded randomize lands the same on every run of one Lua. `gentle_mutate` walks the synth params in `param_order` too. Until the groundwork before 3.8 both followed `pairs` over the voice's `params` table, an order that changed between runs and between the two Luas; ruling 9 fixed it to `param_order`, so a seeded randomize or mutation lands differently from 3.7's.
- There is one undo for the whole script, `S.undo`, cleared by: a randomize (of any page, section or voice: a new one replaces it), a scene recall (`recall_scene` and `recall_scene_instant`), a `gentle_mutate` step that changes a param of the undo's voice (`set_mutated_param`), an edit of a stored param (`note_param_edit`), an edit of a pattern undo's voice's pattern (`S.lib.mutation.note_pattern_edit`) and the end of the window (`undo_clock`); 3.9's holds also end at an edit of what they hold (below). The drift's writes (`S.drift_writing`) and randomize's and undo's own (`undo_writing`) never clear it.
- A quick ALT+K2 undoes only where the undo was made: `undo_for(page, section, voice)` is true for the undo's own page, section and voice within `UNDO_SECONDS`, so a press on another page or section randomizes there (and replaces the undo). A held voice undo (3.8, below) counts on any VOICE section of its voice, and a chain start's patterns (3.9) on SEQ's `pattern` section of any voice.
- **The undo holds more** (3.9, #922, #927; the design's call, no key cancels a learn). Three holds are made outside a page randomize, each at a `where = {page, section}` (no voice; a malformed one raises), each replacing whatever is held, as a randomize does, and each undone only there:
  - `hold_patterns(where, writes)`, a chain start's first link (`lib/sequencer.lua`, at `{SEQ, "pattern"}`): it captures every voice's levels, step attributes and `SEQ.chain_keys` params (`seq_length`, `seq_division`, `seq_direction`, `seq_misstep`), runs `writes` (the link) inside `write_as_undo`, and holds `patterns`, `steps` and the params as `values` and `ids` only when the writes changed any of them (a chain that links nothing leaves an earlier undo). Any voice's pattern or step attribute edit ends it (`note_pattern_edit`), and so does an edit of one of those params (`note_param_edit`), the chain's next link among them.
  - `hold_sequence(n, where)`, a random sequence's `new` (`lib/random_sequences.lua`, at `{MOD, "rseq<n>"}`: the sequence's own section, its source key, so only its row and its settings undo it), before its draws: `sequence = {n, values}`. `S.lib.mutation.note_sequence_edit(n)` (a hand edit, a stored list loaded) ends it.
  - `hold_routing(k, where, writes, depth_id, param_id, before)`, a learn's rewire (`lib/matrix.lua`'s touch hook, at `{MOD, "matrix"}`, `depth_id` the routing's depth param, which the matrix keeps to itself): it runs `writes` (`edit_routing`) inside `write_as_undo` and, when they changed the routing's source, destination or depth (a learn that changes nothing leaves an earlier undo), holds `routing = {k, source, dest, param}` and the depth and the touched param as `values` and `ids`. `before` is the touch hooks' third argument, the touched param's value from before the edit (`lib/ui/detent.lua`). `S.lib.mutation.note_routing_edit(k)` (`set_routing`, `set_home`), a depth edit and any edit of the touched param end it, but the turn that learned going on: `note_param_edit` keeps it for a turn of that param (`S.turning_param`, set by `S.lib.ui_detent.as_turn` around a detent's set, its stop at 0 included), and `set_mutated_param` ends it at a mutation step of that param, which is a turn too. A set (PARAMS, a mapped CC, a scene), a grid fader and a recall end it. The undo puts back the value from before the turn's first detent. Known gap: `filter_mix`, a destination, is the one whose action does not call `note_param_edit`, so a set of it does not end a learn's hold.
  `undo()` puts back, in this order: a routing (`set_routing`), the held params (in `ids` order), the touched param, a single pattern, the seven patterns (`replace_pattern`) and then their step attributes (`S.lib.sequencer.set_step_attr`, a key the step did not have cleared first), a sequence's values (`S.lib.random_sequences.set_value`), all inside `write_as_undo`, so their own edit hooks end nothing.
- **The held voice undo** (3.8, package 3b, ruling 46 as amended): a voice preset's load or copy (`S.lib.voice_presets`) calls `S.lib.mutation.hold_voice(v, capture)` after its apply (whose own param actions are edits), with the voice's sound from before it: `capture = {type, values, preset_name}`, `values` the type's synth keys and the In keys (what a load can change), `preset_name` the name the voice's preset row showed before (a string or nil, #869). It is the one undo, `S.undo`, with `page` VOICE, no `section`, `capture`, no `ids`, and `values` naming every `v<i>_<key>` of the capture and of the voice's synth keys after the load (the loaded type's), so an edit of the old or the new sound (`note_param_edit`), a mutation of the voice, a randomize or a recall ends it; a start, a stop, a source switch, the drift and a write of an Out key do not. `undo()` applies, through `S.lib.scenes.apply_voice` inside `write_as_undo`, the capture's type and values, every other scene key of that type (the Out keys) at its present value, and the voice's present `active` and `source`, then puts the row's name back (`S.lib.voice_presets.restore_name(v, capture.preset_name)`): it puts back what the load changed and nothing else. `undo_for(VOICE, <any section>, v)` says one is held for the voice; VOICE's quick ALT+K2 is the only key that undoes it.
- A binary param a spec draws, and its restore, go through `set_binary_param`, so a controller mapped to it follows (#538).
- `undo_writing` is set around the writes inside an `xpcall` (`write_as_undo`) and then put back to the value it found (#892), so a write nested in another (a randomize inside a randomize's draw) leaves the outer's flag set, the flag never outlives the outermost write, and an error is raised again with its traceback.
- A draws spec of a locked voice (`S.locked[spec.voice]`), or one with no draws, returns false before anything is drawn, stored or cleared. A locked voice can still be edited. A pattern spec randomizes a locked voice's pattern, as SEQ always has: the lock covers params, not patterns.
- The undo's expiry clock runs on the clock helper (`S.lib.clocks`, #870; `docs/notes/lua/clocks.md`): its one wait is `if not handle.sleep(UNDO_SECONDS) then return end`. Every `clear_undo` stops it (`S.lib.clocks.stop`: canceled, or retired when its wake may be posted, so an edit as the window ends prints no clock error and the retired wake clears nothing, not a new undo held since); the clock sets `undo_handle` and `undo_clock` to nil before it clears the undo, so it never stops itself; `hold_undo` stops a clock still running before its replacement starts (an undo held inside another's write, a nested randomize), so no orphaned clock clears the new undo at its own wake. `undo_clock` is the handle's id, which the tests read; cleanup step 85 ends it with `S.lib.clocks.cancel`.

## Machines

### randomize undo
- **State:** `S.undo` (`{page, section, voice, values, ids, pattern, capture, until_time}`, 3.9 adding `patterns` and `steps`, `sequence` or `routing`; or nil), the expiry clock (the local `undo_handle`, its id `undo_clock`) and the local `undo_writing`; `S.lib.mutation.undo_for(page, section, voice)` says whether a quick ALT+K2 there would undo.
- **Invariant:** none: no invariant is registered for it (the audit, `docs/design/3.9-state-machines-facts/lua-scenes.md` section 12, found no transition fault); the held undo and its clock are set and cleared together by `hold_undo` and `clear_undo`, except at cleanup, which cancels the clock and leaves `S.undo` as the script ends.
- **Test:** `test/unit/mutation_test.lua`: "a randomize of another voice, a recall or a mutation of the voice clears the undo", "each hold ends as a page randomize's does (#922, #927)".

Seven states (3.9, #948, #922, #927): none; held draws (a draws spec's `values` and `ids`); held pattern (a pattern spec's `pattern`); held voice capture (a voice preset's load or copy, `hold_voice`'s `capture`); held patterns (a chain start's `patterns` and `steps`, its chain keys in `values`); held sequence (a `new`'s `sequence`); held routing (a learn's `routing`, its depth in `values`). No table: every event leads from any state to the same few ends, which Randomize and its undo (below) lists as rules: a randomize, a pattern randomize, a preset's load or copy, a chain start that links, a `new` or a learned touch replaces whatever is held with its own (a randomize that changes nothing, of a locked voice or of no draws, and a chain start that links nothing, leave the earlier undo); an undo within `UNDO_SECONDS` puts back what is held and leaves none; an edit of a held param, a pattern edit of the voice whose pattern is held (any voice's for held patterns), a hand edit or a load of the held sequence, a write of the held routing, a mutation step that changes a param of the undo's voice, the window's end and a scene recall each leave none.

## Owns

`lib/mutation.lua` (`S.lib.mutation`):
- the per-voice drift: `drift_update`, `mean_reverting_step`, `set_drifted_param` (`S.drift_metro`);
- every page's randomize: `S.lib.mutation.randomize(spec)`, `S.lib.mutation.voice_spec(i)` (MAIN's spec) and `randomize_voice`; `gentle_mutate` (`S.mutation_metro`), `mutated_value`;
- the randomize undo: `S.undo`, `S.lib.mutation.undo_for`, `S.lib.mutation.undo`, `S.lib.mutation.note_pattern_edit`, the held voice undo (3.8: `S.lib.mutation.hold_voice`), 3.9's holds (`hold_patterns`, `hold_sequence`, `hold_routing`, `note_sequence_edit`, `note_routing_edit`, and the locals `check_where`, `same`, `copy_of`, `capture_patterns`, `restore_steps`), the globals `undo_available`, `undo_randomize`, `clear_undo`, `note_param_edit`, and the locals `undo_handle`, `undo_clock` (its id), `undo_writing`, `write_as_undo`, `set_randomized_param`, `check_spec`, `hold_undo`, `set_mutated_param`;
- `S.drift_writing`, `S.grain_pitch_base` and `S.buf_pos_base`, on `S` because the grain pitch and buffer position param actions read them;
- cleanup steps 70 (drift metro), 80 (mutation metro) and 85 (the undo's expiry clock).

Elsewhere:
- Its start steps (`START_ORDER.drift_metro`, `mutation_metro`) create `S.drift_metro` and `S.mutation_metro` at init.
- `drift_update` calls `S.lib.grid_faders.follow_faders()` (`lib/grid/faders.lua`), which redraws the grids only when a fader line or a page signature a pane shows moved, whoever moved it (#324; `docs/notes/lua/grid/pane.md`).
- `UNDO_SECONDS` is in `lib/constants.lua`, aliased at the top of the constructor. The keys and draws `voice_spec` and `mutate_voices` use are the records' (`main_randomize`, `mutate`; the built-in ones in `lib/voices.lua`), each group's keys read through `S.lib.params_setup.group_keys`.
- The actions of the params a randomize sets call `note_param_edit` (`lib/params_setup.lua`); `recall_scene` and `recall_scene_instant` call `clear_undo` (`lib/scenes.lua`).
- 3.9's holds are made by `lib/sequencer.lua` (`start_patterns`), `lib/random_sequences.lua` (`new`) and `lib/matrix.lua` (the learn's touch hook); the ends are theirs too (`set_step_attr` and `replace_pattern`, `set_value` and `load_lists`, `set_routing` and `set_home`). The places a quick ALT+K2 undoes them are SEQ's `pattern` spec, MOD's per-sequence spec (`lib/pages/mod.lua`: no draws, section the sequence's source key, on its row and in its settings) and MOD's `matrix` spec (one with no draws while a learn's undo is held and no routing is complete).
- The ALT+K2 that calls `randomize` and `undo`, and its hint, are the shared handler's (`S.lib.ui_alt.k2_up`, `k2_hint`, `docs/notes/lua/ui/alt-and-keys.md`); each page's spec is its record's `randomize_section` (MAIN's: `docs/notes/lua/pages/main.md`).
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
    if S.voices[i].active and not S.locked[i] then
      -- synth source: each synthesis parameter
      for _, key in ipairs(S.voices[i].param_order) do
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
  - a buffer-sourced voice mutates its buffer params (the grain record's first `mutate` group: `buf_pos`, `buf_rate`, `buf_scan`, each with `probability`; delta = gaussian × `amount` in the controlspec's normalized range, so the exp `buf_rate` moves evenly) instead of its synthesis params;
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
- **`voice_spec(i)`** is MAIN's whole-voice spec, `{page = MAIN, section = "voice", voice = i, draws}`: synth params but `amp` (`spec:map(math.random())`) for a synth source, `buf_pos` (r), `buf_rate` (`2 ^ (2r - 1)`) and `buf_scan` (r - 0.5) for a buffer source, nothing more for input; then `grain_size` (0.3r + 0.05) and `grain_pitch` (2r + 0.5). The draws are the same as before #557, the synth params' in `param_order` (ruling 9 of the groundwork before 3.8; `pairs` order before). `randomize_voice(i)` is `randomize(voice_spec(i))`, returning false at once for an index outside 1..`NUM_VOICES`.
- **`undo_for(page, section, voice)`**: `S.undo` is that page's, section's and voice's (`nil` matches `nil`) and `util.time() < until_time`. `undo_available(i)` is `undo_for(MAIN, "voice", i)`, MAIN's undo of voice `i`.
- **`undo()`** (and the global `undo_randomize()`): false when nothing is held or its window has ended; otherwise it clears the undo, then puts every stored value back through `set_randomized_param`, in the order the randomize set them (so a pair a section draws in order, a loop's start then its length, comes back whole), so the LFO offsets, the engine and the grid follow, and a pattern's old steps through `S.lib.sequencer.replace_pattern`, and returns true. The grain pitch and buffer position actions take the restored values as the drift's new centers.
- `clear_undo()` stops the expiry clock (`S.lib.clocks.stop`), drops `S.undo` and requests a redraw.
- The expiry clock (`undo_handle`, its id `undo_clock`) sleeps `UNDO_SECONDS` through its handle and clears the undo, which requests the redraw that puts the ALT hint back without input; stopped as its wake is posted, it wakes and does nothing. Cleanup step 85 cancels it (`S.lib.clocks.cancel`).
- `note_param_edit(param_id)` is called from the actions of every param a randomize sets. It clears the undo when `param_id` is stored, unless the drift (`S.drift_writing`) or randomize/undo (`undo_writing`) is writing. PARAMS edits, MIDI CC maps, pset loads, grid faders and arc rings all arrive through those actions.
- `S.lib.mutation.note_pattern_edit(voice)` clears a pattern undo of that voice, unless randomize/undo is writing. Only a pattern spec holds a pattern undo, and SEQ is the page that hands one in (#557): every pattern edit calls this (`lib/sequencer.lua`'s `toggle_pattern_step` and `replace_pattern`, which a clear goes through, SEQ's E3 step level, the arc's SEQ rings and the grid's step-level keys).
- `gentle_mutate` writes through `set_mutated_param(voice_idx, param_id, value)`, which marks the step a turn of the param (`S.lib.ui_detent.as_turn`, #318) and clears the undo when the step changed a param of the undo's voice, stored or not (grain spread too).
- A scene recall clears it: `recall_scene` (after validation, before a fade starts) and `recall_scene_instant` (so a fade's end does too).
- 3.9's three holds (a chain start's patterns, a sequence's `new`, a learn's rewire: Must not break, "The undo holds more") end as a randomize's does, and a quick ALT+K2 where each was made (SEQ's patterns, MOD's sequences, MOD's matrix) undoes it.

## Drift and the other systems

- **Drift**: mutations run alongside `drift_update()` (the per-voice drift, not the global LFOs). It gives each active, unlocked voice a subtle mean-reverting grain pitch drift:
  - `mean_reverting_step(current, base, DRIFT_PITCH_STEP, DRIFT_PITCH_REVERSION)` = `current + ((math.random() - 0.5) * step - (current - base) * reversion)`;
  - step 0.004, reversion 0.01 per 100 ms tick; one `math.random()` per call.
  - `base` (`S.grain_pitch_base[i]`) is the last grain pitch set by anything other than the drift (user, mutation, scene). The param action tracks it through the `S.drift_writing` flag, which the drift sets around each write in `set_drifted_param` (an `xpcall` with `with_traceback`: an error in the param action clears the flag and is raised again with its traceback).
  - The `grain_pitch` controlspec has step 0, so these small steps are not quantized away.
  - Buffer-sourced voices also drift `buf_pos` with the same helper (`DRIFT_BUF_POS_STEP` 0.002, `DRIFT_BUF_POS_REVERSION` 0.01, center `S.buf_pos_base[i]`, `buf_pos` step 0).
- **Lock** (`S.locked`, the scene field `locked`): locked voices are stable. Neither the drift nor mutations affect them (buffer params included), and `randomize_voice` returns for a locked voice.
- **Cross-modulation**: mutations never touch the crossmod sources or amounts. The routing a voice has (set by hand or by a scene) keeps modulating the mutated params.
- **UI feedback**: `[M]` appears in the header (x=76) while mutations are on.

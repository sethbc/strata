# Plan facts: 1a, the value table, the start path and scene format 9

Read-only survey of the worktree at 61e07acb (lib/ and test/ identical to `main`). Counts are from grep. Key sets, the start's and a sync's messages and the per-voice table count come from two scratch runs of `h.load_strata()` (scratchpad only). Line numbers are today's. Package 0a (`frozen` to `locked`; the floor and version to 9, `plan-0a-locked.md:67`) runs first and moves some of them.

## The key map

New key = the param id without `v<i>_`. Every key below has a param, and no param or field is left without a key, apart from these:

- `v<i>_source` stays the field `source`.
- The fourteen `out_*` and `zone*` params stay where they are (design §2).
- `active`, `name` and `param_order` stay fields.

| Today | New `values` key |
|---|---|
| `params.<k>` (by voice, below) | `<k>` |
| `grain.size`, `.density`, `.pitch`, `.spread`, `.env`, `.mode` | `grain_size`, `grain_density`, `grain_pitch`, `grain_spread`, `grain_env`, `grain_mode` (`GRAIN_PARAM_IDS`, constants.lua:130-140) |
| `grain.buf_pos`, `.buf_rate`, `.buf_scan` | unchanged |
| `crossmod.slotN.source`, `.amp_amt`, `.freq_amt` (N = 1-3) | `mod_source_N`, `mod_amp_amt_N`, `mod_freq_amt_N` |
| `crossmod.speed` | `mod_speed` |
| `extras.<k>` (53 keys, 12 records) | `<k>` |

The synth keys are `param_order`, and that equals the set of keys of `params` for every voice (voices.lua:22-205; checked at load):

- v1 resonator: freq, rq, noise, mod1, mod2, amp, pan
- v2 fm: freq, ratio, index, modFreq, amp, pan
- v3 folder: freq, fold, mod, amp, pan
- v4 sub: freq, drift, amp (no pan)
- v5 pulse: freq, width, cutoff, res, amp, pan
- v6 karplus: freq, decay, damping, excite, amp, pan
- v7 ring: freq, ratio, mod, brightness, amp, pan

That gives 75 to 79 keys a voice. The 53 registered keys are:

- attack, release, note_cap
- bookmark_1-4
- custom_interval_1-5, intervals, interval_prob, quantize, reverse, pitch_jitter, pan_jitter, size_jitter
- delay_send, reverb_send, filter_type, filter_freq, filter_res, filter_mix, mute, solo
- env_attack, env_decay, env_sustain, env_release, env_curve, env_loop
- follow, scan_mode
- freeze, freeze_mode
- history
- loop_start, loop_length
- press_target, press_depth, slide_target, slide_depth
- seq_length, seq_division, seq_direction, seq_misstep, seq_swing, seq_gate, seq_gate_length, seq_gate_release
- slices

**Collisions: none.** No built-in key equals a registered key or one of the 14 IO and zone keys. Near misses that are distinct keys: `mod` against `mod_*`, `res` against `filter_res`, `decay` against `env_decay`. For 3.8: the notes record's `attack` and `release` have generic names that a future synth key could take.

**Values in a table but not scene keys:** `solo` and `note_cap`. They have no `scene_defaults` (notes_test.lua:1012).

## 1. Files

**lib/ (the readers of the four tables)**
- `lib/voices.lua:17-232`: the seven voices' `params`, `grain` and `crossmod` become one flat `values = {...}` each, holding the defaults. Header lines 1-6.
- `lib/params_setup.lua`:
  - `add_voice_extra` (806-842): the store moves to `values` (sites 825, 827-828, 834; comment 801).
  - `add_voice_params` (902-1193): line 907 `v.extras = {}` goes. The reads and writes change: `.params` at 920, 929, 930; `.grain` at 18 lines (977-1110); `.crossmod` at 7 lines (1119-1181).
  - New `voice_engine_parts` and `voice_scene_keys` (Names).
- `lib/engine_sync.lua:677-822`: `send_registered_voice_values` (697-711), `send_grain_params` (720-734), `send_synth_params` (736-740), `send_crossmod_and_bend` (742-754), `sync_voice_values_to_engine` (761-769), `start_voice` (793-822). Line 700 is the file's only read of `S.registry.voice_params`.
- `lib/scenes.lua`:
  - Header comments 10 and 14; the aliases 33-34.
  - `VOICE_SCENE_DEFAULTS` (121-133) and `registered_voice_scene_keys` (135-149).
  - `fill_scene` (271-321), `capture_scene` (323-385), `scene_entries` (436-490).
  - `validate_scene` (1240-1280).
  - The exports (1486-1491).
- `lib/constants.lua:117-141, 347-349`: the `DISCRETE_GRAIN_KEYS` keys become `grain_env` and `grain_mode`. `GRAIN_PARAM_IDS` goes (recommended). `BUFFER_MUTATION_KEYS` stays: its keys are already suffixes.
- `lib/mutation.lua`: 32, 33, 203, 277, 283, 329, 349, 354, 367, 371.
- `lib/variation.lua`: 92, 106, 127-143, 228, 302, 341, 384.
- `lib/sequencer.lua`: the helper at 164, renamed `voice_values`, and its 8 calls (166, 169, 172, 174, 176, 458, 886, 1064); also 1173-1175 (the chain's link reads `data.voices[v].extras`).
- One or two lines each:
  - `lib/notes.lua:121-122, 893-895`
  - `lib/envelopes.lua:54-63, 124`
  - `lib/voice_mix.lua:52, 67-68`
  - `lib/freeze.lua:47-48`
  - `lib/buffers.lua:627-628`
  - `lib/slices.lua:391`
  - `lib/loops.lua:51, 109-114`
  - `lib/expression.lua:74-76`
  - `lib/pages/main.lua:178`
  - `lib/pages/voice.lua:204`
  - `lib/arc/main.lua:41`
  - `lib/grid/faders.lua:35`
  - `lib/ui/voice_rows.lua:42`
  - `lib/state.lua:183` (a comment)
- `lib/data_files.lua:32-39`: `largest_scenes_tables` goes from 7474 to 6802 (Tests).

**Grep counts (lib/ and strata.lua):**
- `.extras`: 32 lines (35 uses) in 14 files, three of them comments. This matches the design's facts.
- Voice `.params`: 20 lines in 9 files (the facts said 17).
- `.grain`: 45 lines in 6 files, three of them comments in constants.lua (the facts said 38 in 5).
- `.crossmod`: 17 lines in 3 files.
- Not voice tables, and unchanged: the `extras` in engine_sync.lua:104-110 and 413-425 (`extra_offsets`), macros.lua:169-280 and matrix.lua:209-435.
- strata.lua has none.

**Code that is not a mechanical rename:**
- These iterate a table with `pairs`: engine_sync.lua:737, scenes.lua:357, 360, 469, 471, 1255 and 1258, and mutation.lua:203 and 329.
- These rely on the nesting: scenes.lua:364-372, 474-480 and 1263-1270, and engine_sync.lua:744-751.
- pages/voice.lua:204 tests synth membership by `params[key] ~= nil` (Risks 2).

**Tests:**
- Voice-table and scene-table sites: about 211 lines in 23 unit files, plus `test/helpers.lua:675-693` (`assert_voice_matches`, which reads the nested shape).
- Lines per file:
  - scenes_test 55
  - params_setup_test 29
  - registries_test 19
  - mutation_test 18
  - loops_test 17
  - variation_test 10
  - notes_test 8
  - 5 each: voice_mix, scan, history, engine_sync
  - 4 each: positions, envelopes
  - 3 each: voices, sequencer, io_nb
  - 2 each: lfos, freeze, buffers, system_37
  - 1 each: pages_voice:825, pages_main:377, midi_in, arc_pages
- Out of scope: `sent.grain` and `state.grain` are the engine-state helper (helpers.lua:755-760), not voice tables, and stay.

**Notes and docs:**
- `docs/notes/lua/scenes.md` has 24 lines on the shape, entries order, fill and validate: 3, 5, 15, 47, 62-80, 140-143, 186-188, 290-301, 330-343, 361-362.
- `docs/notes/lua/engine-sync.md:35-36, 139-148`
- `docs/notes/lua/state-and-voices.md:23, 37`
- `docs/notes/lua/params.md:19, 38, 70, 75-77`
- The 7474 figure: `docs/notes/lua/data-files.md:6, 33`, `docs/notes/lua/matrix.md:59`, `docs/notes/lua/macros.md:16`, `docs/notes/lua/random-sequences.md:8`, `docs/status.md:36`.
- `docs/notes/lua/mutation.md:3-4, 34, 89`
- `docs/notes/engine/grains.md:16-18`, `docs/notes/engine/buffers.md:61`
- `docs/notes/lua/loops.md:13-14, 25`, `docs/notes/lua/arc-pages.md:37`
- One line each saying "stored in `S.voices[i].extras`": `freeze.md:3`, `history.md:12, 14`, `voice-mix.md:27`, `variation.md:12`, `sequencer.md:54`.
- User pages: none. Menu names stay, including the `voice <i> extras` separator.

**AGENTS.md lines 1a makes false:**
- Line 320: "... Grain params go through `setGrainParam` and `GRAIN_PARAM_IDS`." It becomes false if `GRAIN_PARAM_IDS` goes; drop the last three words. 2a rewrites the rest of the line (it removes `add_voice_params`).
- Lines 189, 234 and 252-253 stay true.
- Line 305 is 0a's.

## 2. Names

**Removed or changed:**
- `S.voices[i].params`, `.grain`, `.crossmod`, `.extras` become `S.voices[i].values`. Tests reach the voices through `local_value("voices")` (93 uses).
- `S.VOICE_SCENE_DEFAULTS` (scenes.lua:126) goes (tests: params_setup_test.lua:43, 102, 343; scenes_test.lua:1290).
- `S.constants.GRAIN_PARAM_IDS` goes (tests: params_setup_test.lua:46, 326, 344; scenes_test.lua:2074, 2118, 2174, 2228).
- `DISCRETE_GRAIN_KEYS` is keyed `grain_env` and `grain_mode` from now on. mutation.lua:367 then tests `[mutation.param]`. Tests: mutation_test.lua:127-128 and 327-328, scenes_test.lua:2174 and 2227.
- The local `registered_voice_scene_keys` (scenes.lua:140) goes; `voice_scene_keys` replaces it.
- The local `extras(voice_idx)` (sequencer.lua:164) becomes `voice_values`.
- The four local senders (engine_sync.lua:697-754) are replaced by one loop over the parts. No test reaches them.

**Added (proposed):**

1. `S.lib.params_setup.voice_engine_parts(voice_idx)`: an array of parts, each `{name, kept = {entry...}, voice_level = {entry...}}`.
   - The parts, in order:
     - `synth`: its `voice_level` is the voice's synth keys, sorted, each `{key = k, voice = k}`.
     - `grain`: its `kept` is the 9 in today's fixed order:
       - `{key = "grain_size", grain = "grainSize"}`
       - `grain_density` with `value = x × engine_param_value("master_density")`
       - `pitchShift`, `posSpread`
       - `grain_env` and `grain_mode`, each `value = x - 1, carry = false`
       - `bufPos`, `bufRate`, `bufScan`
     - `crossmod`: its `voice_level` is, per slot: `{key = "mod_source_N", carry = false, send = fn(v, x) engine.setModSource(v - 1, N, engine_mod_source(x)) end}`; the amp and freq amounts (setModAmpAmt and setModFreqAmt, `carry = false`); then `mod_speed` (setModSpeed, `carry = false`).
     - `bend`: one keyless `send` (setVoiceParam "bend", `S.midi_state.bend[v]`).
     - Then one part per `S.registry.voice_params` record, in registration order. Its `kept` is its `grain_keys`, sorted, each `{key, grain = name, value}` (from `grain_key_message`), and then `{send = record.sync}` when it has a sync.
   - Each entry has exactly one of `grain`, `voice` or `send`. Engine calls stay literal `engine.<name>(`, since `test/sync_check.lua` refuses any dispatch through `engine`.
   - engine_sync then does this:
     - **A start:** the source; every part's `kept`; `voiceOn`, as today, from `values.freq`, `.amp`, `.pan or 0`, `.grain_size`, `.grain_density × master` and `.grain_pitch`; the hooks; every part's `voice_level`.
     - **A sync:** per part, its `voice_level` and then its `kept`.
   - That reproduces both of today's orders exactly, with the synth group sorted.
   - 2a fills the parts from records, and must keep the built-in parts first and the grain part's fixed order. Sorted `grain_keys` cannot express that order (engine_sync.lua:701-703).
2. `S.lib.params_setup.voice_scene_keys(voice_idx)` returns `list, by_key`. `list` is ordered `{key, default, range | nil, limits | nil}`, and `by_key` maps a key to its entry.
   - The built-in keys of that voice: its synth keys, the 9 grain keys and the 10 crossmod keys.
   - Each built-in default is `param_default("v<i>_<key>")` (ui/params.lua:52), read after init, because live values overwrite the voices table.
   - The ranges: `grain_env` {1, 5}, `grain_mode` {1, 2}, `mod_source_N` {0, `NUM_VOICES`}.
   - Then the registered keys (scenes.lua:140-149 moved here, with `S.voice_scene_defaults(record, voice_idx)`).
   - Order: Risks 1.
3. `S.lib.voices.is_synth_key(voice_idx, key)`: true when `key` is in `param_order` (Risks 2).
4. `S.lib.scenes.voice_entries(voice_idx, voice_data)`: the entries of `active`, source and values, in recall order. `scene_entries` becomes: the blocks, the globals, per voice `voice_entries` plus its lock entry, then the patterns.
5. `S.lib.scenes.capture_voice(voice_idx)`: a fresh `{active, source, values}`, where `values` holds the scene keys only; nil for a bad index.
6. `S.lib.scenes.apply_voice(voice_idx, data, opts)` returns a boolean:
   - It applies nothing and returns false for a bad index, or for data still invalid after a fill (one console line).
   - It fills a deep copy: the missing keys, then each record's `normalize_scene`.
   - It runs `apply_entries(voice_entries(...), opts)`. So the voice is stopped or started by `active`, the source goes first, and a running voice whose source changed gets one sync (scenes.lua:595-600).
   - It leaves the pattern, the lock, the globals, the blocks, `S.current_scene` and a running transition alone.
7. Factored locals: `fill_voice` and `valid_voice_data`, used by `fill_scene`, `validate_scene` and `apply_voice`.

**Unchanged and reached by tests** (`MODULE_HOMES`, structure_test.lua:401-422): `add_voice_params`, `get_param_spec`, `sync_voice_values_to_engine`, `toggle_voice`, `capture_scene`, `fill_scene`, `validate_scene`, `recall_scene_instant`, `scene_transition_targets`. `add_voice_extra` keeps its name (2a renames it).

**The format-9 voice:** `{active = bool, source = 1..10, values = {key = number}}`. `validate_scene` checks:
- that `values` holds exactly `voice_scene_keys(i)`'s keys: an unknown key is rejected as today (decisions 3.2:11), and a missing one too (new);
- that every value is a finite number;
- that a key with `range` holds a whole number in it, and one with `limits` a value in them.

Another type's synth keys fail, as scenes.lua:1256 does today.

## 3. Order and seams

**Today's start** (observed): `setGrainSource`; the grain 9 in fixed order; per record, its grain keys sorted, then its `sync`; `voiceOn`; the hooks (`attackTime` and `releaseTime`); the synth params in `pairs` order; crossmod per slot (source, amp, freq), then the speed; `bend`.

**Today's sync** (761-769): the synth params (`pairs`), the grain 9, crossmod and bend, the registered values, then the resend of modulated params.

**`pairs`-dependent today:**
- the synth sends (737);
- the recall order of synth and grain keys (scenes.lua:469, 471; scenes.md:143);
- MAIN's randomize (mutation.lua:203) and the mutation draws (329).

**Carry:** today `envShape`, `grainMode` and crossmod take no `start_value` (720-751). The parts' `carry = false` keeps that.

**Recall order today**, per voice (scenes.lua:463-487): active; source; the synth keys (`pairs`); the grain keys (`pairs`); crossmod; the registered keys sorted across all records; lock. The patterns follow every voice. These depend on the order:
- The loop pair: `loop_length` before `loop_start`. Sorted order keeps it.
- `quantize` before `freq` is PSET order only (`add_first`). A recall stands down: `freq_filter` and the quantize action skip while `S.scene_recall_in_progress` (variation.lua:203, 322).
- The source: its entry comes first and the sync after. Unchanged.
- **New:** `freeze` before `freq` (Risks 1).

**Seams for 2a:**
- 1a leaves `S.register_voice_params` and its fields alone, the name `add_voice_extra`, and the hand-written `add_voice_params` (it now writes `values`).
- 1a also leaves alone `VOICE_PARAM_SPECS`, `get_param_spec`, the defaults in voices.lua, the fixed lists in faders.lua:20-23 and voice_rows.lua:17-18, mutation's synth loops and the separators.
- 2a replaces only what sits behind the two params_setup functions.
- 2a must keep the built-in parts first even though include order registers the modules' records before params_setup.lua.

**Conflicts:** none in wave 1. 1a touches none of lib/io/midi_out.lua, ii.lua, txo.lua, remote.lua or ports.lua: grep finds no read of the voice tables under lib/io/. It does not touch lib/engine/StrataPositions.sc either.

**Rules:**
- **scenes.md "Must not break" line 15** (sorted, never `pairs`): kept, and extended.
- **scenes.md:188** (extras after the built-ins): a fully sorted order breaks it (Risks 1).

## 4. Tests

**Re-based (not mechanical):**
- `scenes_test.lua:2319` and `:2359`: the 3.3.2 references (2063-2240) read the nested tables with `pairs`. They become references over `values` in recall order, and the call-by-call comparison stays.
- `scenes_test.lua:62` (87-94) and `:1901-1905`: the rejects become `values` keys.
- `scenes_test.lua:1290`: a missing key is filled with its default.
- `scenes_test.lua:3239`'s field deletions: 0a's test, with 1a's shape.
- `params_setup_test.lua:12`, `:28-70`, `:88-125` and `:315-350` become "every `voice_scene_keys` default equals `param_default`".
- `registries_test.lua:585-610` and `:633-638` move to `values`.
- `mutation_test.lua:118` and `:322`: the injected discrete keys become `grain_size`, `grain_pitch` and so on.
- `helpers.lua:675-693` `assert_voice_matches` compares `values`.
- `system_37_test.lua:88`: no change. `canonical()` (51-68) already compares the `setVoiceParam` runs as sets, and keeps working since the run after `voiceOn` starts with the hooks' two. Its 3.6-file test (252) is 0a's (`plan-0a-locked.md:99-103`).

**New (design §11):**
- `params_setup_test.lua`: "every param's id, default and spec is 3.7.0's", against `test/fixtures/3.7.0-params.lua`, recorded from tag v3.7.0 as 3.6.0-start-calls.lua was (its header, 9-17). Record it first, so it guards 1a and 2a.
- `engine_sync_test.lua`:
  - "a voice start sends 3.7.0's messages": with `canonical`, or a 3.7.0 start-calls fixture.
  - "the synth params go out sorted": voice 1 gives `amp`, `freq`, `mod1`, `mod2`, `noise`, `pan`, `rq` after the hooks' two; on LuaJIT too.
  - "voice_engine_parts names `synth`, `grain`, `crossmod`, `bend`, then the records".
  - "a sync sends `voice_level` before `kept`, per part".
  - "engine_sync.lua reads no `S.registry.voice_params`".
- `scenes_test.lua`:
  - "`capture_voice` holds exactly the scene keys": no `note_cap` or `solo`; Sub has no `pan`.
  - "`apply_voice` round-trips a voice and leaves the other six, the patterns, the locks and the globals unchanged": `encode` the six `capture_voice` results before and after.
  - "`apply_voice` refuses an unknown key and applies nothing".
  - "`apply_voice` sends one sync on a source change" and "it starts an active voice after its keys".
  - "a recall applies a voice's keys in the documented order".
  - "a recall that freezes a running synth voice takes its reference from the scene's freq" (Risks 1).
- `random_sequences_test.lua:380-395`: base 7394 becomes 6722, figure 6802.
  - 6802 = 7474 - 16 × 7 × 6: 8 tables a voice today (measured: the voice, params, grain, crossmod, 3 slots, extras), 2 after.
  - `matrix_test.lua:1426` asserts the written count equals the constant, so the constant changes in the reshape's commit.

## 5. Risks and open points

1. **A fully sorted recall order changes a behavior: the design is wrong or silent here.**
   - `freeze` sorts before `freq`. The freeze hook takes a running synth voice's reference from the freq the engine plays at that moment (notes.lua:1042-1045, 133-136). The reference then sets `scaleNote` and the note rates. Today the scene's freq is set first; sorted, the old freq is used.
   - `bookmark_*`, `attack`, `intervals`, `custom_interval_*`, `env_*`, `filter_*` and `follow` also move ahead of built-in keys. I found no other dependency; scan's and positions' actions were not read exhaustively: unsure.
   - Recommendation: the order is the built-in keys sorted, then the registered keys sorted. That is today's order with `pairs` made sorted, and it keeps scenes.md:188.
2. **pages/voice.lua:204 must not become `values[key] ~= nil`.** `scan_mode`, `follow` and `slices` rows are in the `synth` section (scan.lua:25, slices.lua:31) and have no draw. A buffer voice's ALT+K2 would call `controlspec:map` on an option param and raise. Use `is_synth_key`. The `pan` checks (faders.lua:35, voice_rows.lua:42, arc/main.lua:41) work as `values.pan ~= nil`.
3. **A recall built from seven `apply_voice` calls** would run the scene-applied hooks (delay_sync's send among them) and set the recall flag 8 times. Build it from `voice_entries` instead. How `apply_voice` treats a running fade is 3.8's to settle; the design is silent.
4. **The format-9 fixture** goes to the last package that changes the file (2b's block, or 4a's field), as `plan-0a-locked.md:77` also says.
5. **Validation:** I recommend requiring every key, since the fill always runs first.
6. **AGENTS.md:320:** the design's §10 list gives 1a no AGENTS.md line. Either 1a shortens it, or 1a keeps `GRAIN_PARAM_IDS`, unused, for 2a to drop.
7. **Mutation:** `pairs` becomes `ipairs(param_order)`. No test can pin a `pairs` order, so none breaks.
8. **Unsure:** whether any test pins a recall's call order across runs. morph_test.lua:38-55 is by id; scenes_test:2319 compares within one process.

**Suggested split (each commit green on Lua and LuaJIT):**
- (0) The 3.7.0 params fixture and the start test, which pass on today's code.
- (A) `voice_engine_parts` over the old tables; engine_sync loops over the parts; the synth group sorted.
- (B) Format 9, with the live tables still the old ones:
  - `voice_scene_keys` (through one local map);
  - `capture_voice`, `voice_entries`, `apply_voice`, fill and validate;
  - sequencer.lua:1173, loops' `normalize_scene`;
  - 6802 and its test;
  - the scene tests re-based; `assert_voice_matches`.
- (C) The value table and every reader, the constants and `is_synth_key`, the tests' renames. The map from (B) goes.
- (D) Notes, `docs/status.md:36`, AGENTS.md:320 and the fragment.

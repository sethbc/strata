# Plan facts: 2a (records for the built-ins, the faders) and 3b (MIDI note off)

Read from `main`. Counts are from `grep`. For 3b I ran the whole Lua suite once on a scratch copy (under the session scratchpad, not the repo) with the two-line note-off change; its failures are listed under 3b Tests.

# Package 2a

## 1. Files

**Code (2a's own):**
- `lib/state.lua`: `:151-153` (`VOICE_PARAM_FIELDS`), `:157-160` (`is_grain_key`), `:172-195` (the record's doc comment), `:196-251` (`register_voice_params`; `:246` is the `fader ~= true` refusal).
- `lib/params_setup.lua`:
  - `:763-765` `add_voice_sender`;
  - `:773-792` `filtered_value` and `turn_on_own_delta`;
  - `:794-845` `add_voice_extra`;
  - `:847-893` the add_first and add loops and their checks;
  - `:895-900` `VOICE_PARAM_FORMATS`;
  - `:902-1193` `add_voice_params`, 291 lines: 911 the heading separator, 915 the add_firsts, 918-937 the synth params, 940 the "granular" separator, 944-970 source, 972-1115 the nine grain params, 1120 the "cross-modulation" separator, 1125-1186 crossmod, 1189-1192 the "extras" separator and the records;
  - `:1198-1227` `VOICE_PARAM_SPECS` and `get_param_spec` (keep them).
- `lib/voices.lua` (after 1a): register the three built-in records here (see Order and seams).
- `lib/mutation.lua`: `:17-18` (the aliases), `:198-216` `voice_spec`, `:317-381` `mutate_voices`. Inside them: `pairs(v.params)` at 203 and 329, `BUFFER_MUTATION_KEYS` at 348, the inline grain list at 362-366, and the `DISCRETE_GRAIN_KEYS` guards at 349 and 367.
- `lib/grid/faders.lua:17-65`: `BUFFER_FADER_KEYS`, `GRAIN_FADER_KEYS`, `append_fader_ids`, `voice_level_fader_keys` and `fader_param_ids`. `fader_page_count` (67-69) is unchanged.
- `lib/ui/voice_rows.lua`: nothing beyond 1a's `params.pan` read at :42, if `section_keys` stays (recommended, Risks 4).
- **The rename** of `add_voice_extra` to `add_voice_param`, measured with `grep -o`:
  - 18 calls in 12 files: `lib/freeze.lua`, `variation.lua`, `loops.lua`, `expression.lua`, `notes.lua` and `scan.lua` 2 each; `history.lua`, `positions.lua`, `slices.lua`, `envelopes.lua`, `voice_mix.lua` and `sequencer.lua` 1 each.
  - `lib/params_setup.lua`: 8 (the definition at 806, four error strings at 808-817, comments at 10, 794 and 906).
  - Comments in `lib/state.lua:175` and `lib/mutation.lua:230`.
- **The `fader` lines.** All 12 records have `fader = false`: `freeze.lua:128`, `variation.lua:345`, `slices.lua:505`, `expression.lua:519`, `loops.lua:146`, `history.lua:68`, `sequencer.lua:1698`, `envelopes.lua:333`, `positions.lua:908`, `scan.lua:254`, `notes.lua:932`, `voice_mix.lua:200`. Four of them become lists: `voice_mix`, `loops`, `variation` and `notes`.
- **Optional:** `lib/constants.lua:121-127` (`DISCRETE_GRAIN_KEYS`, `BUFFER_MUTATION_KEYS`) are dead after 2a if 1a has not already removed them. `lib/constants.lua` is not in 2a's list of files (Order and seams 3).

**Tests:**
- `test/unit/registries_test.lua`:
  - 9 `add_voice_extra` occurrences (lines 3, 27-30, 145, 435, 442, 528);
  - `:176` refuses `fader = true` (re-base);
  - `:683-703` checks that randomize, the mutations and the faders never touch a probe record (keep);
  - `:705` checks that every registered scene default equals its param's default, and now covers the built-ins too.
- **Other test call sites of `add_voice_extra`:** `arc_pages_test.lua` 2 (787, 830), `engine_sync_test.lua` 1 (173), `pages_voice_test.lua` 3 (169, 214, 221), `scenes_test.lua` 2 (2039, 3351).
- **Fader-exclusion asserts to re-base**, because their params now have faders:
  - `voice_mix_test.lua:268` (the filter and sends; `:544`, mute and solo, stays);
  - `loops_test.lua:334`;
  - `variation_test.lua:596` (only the three jitters move).
  - Unchanged: `history_test.lua:218`, `freeze_test.lua:294`, `positions_test.lua:692`, `registries_test.lua:699`, `io_jf_test.lua:181`, `io_nb_test.lua:582`, `io_system_test.lua:1601`.
  - `freeze_test.lua:65` and `scan_test.lua:344` assert `record.fader == false`; they stay if `false` stays allowed.
- **Page counts:**
  - `grid_layout_256_test.lua:19-25`: fm has 21 faders and 6 pages; resonator 6, folder 5, sub 5.
  - `:323-358`: resonator's page 6 is clamped to 5 on a buffer switch; `#ids == 5 + 6 + 9`.
  - `:1138-1150`: folder has "5 fader pages"; the test presses 6 and 16.
  - `voices_test.lua:24-25`: an input voice has `6 + 2 + 9` faders and 5 pages; an input-sourced Sub 4 pages.
  - `grid_layout_128h_test.lua:146-216, 826-907` and `grid_layout_128v_test.lua:62, 210-251, 704-771` read `fader_page_count` and positions in `fader_param_ids`. Verify them, but they mostly compute the counts rather than pin them.
- **Mutation guards:** `mutation_test.lua:118-136` and `:320-335` stop keys mutating by writing into `local_value("DISCRETE_GRAIN_KEYS")`. Both must be re-based to point at the grain record's `mutate` groups.
- **The proof of the move:** `params_setup_test.lua:11-27, 398-440, 520-583` pin param_order, the specs, the separators and crossmod. They should pass unchanged.
- **`MODULE_HOMES`:** `structure_test.lua:421` (`add_voice_params`, `get_param_spec`) is unchanged. `:441` lists `voice_level_fader_keys`; keep it, since I reuse it (Names).

**Notes and docs:**
- `docs/notes/lua/params.md` (lines 8, 18, 19, 34, 38, 71, 74-77, 118)
- `docs/notes/lua/state-and-voices.md:37`
- `docs/notes/lua/mutation.md:3-4, 13, 34, 89`
- `docs/notes/lua/engine-sync.md:36, 148`
- `docs/notes/lua/grid-core.md:41, 153-155`
- `docs/notes/lua/grid/layout_256.md:54`
- `docs/notes/lua/loops.md:7`, a Must-not-break line: "the 256 fader pages never touch them"
- `docs/notes/lua/voice-mix.md:7`, `docs/notes/lua/variation.md`, `docs/notes/lua/notes.md:73`
- `docs/notes/engine/buffers.md:58`
- `docs/user/grid/256.md:33-34` (the fader list)

**AGENTS.md lines 2a makes false:**
- **Line 250** reads: "**Registered per-voice params** (freeze, variation, loops, history, voice mix, seq) default to 3.1's sound and never reach MAIN's randomize, mutations or the 256 fader pages (`fader = false`), but for their own section's page randomize; registered LFO destinations join their voice's group. `docs/notes/lua/params.md`".

  A replacement no longer than it: "**Per-voice params** are `S.register_voice_params` records (the built-ins `synth`, `grain`, `crossmod` first), added with `add_voice_param`; a record names the keys MAIN's randomize, the mutations and the fader pages reach (`main_randomize`, `mutate`, `fader`); registered LFO destinations join their voice's group. `docs/notes/lua/params.md`"
- **Line 320** reads: "A new SynthDef argument the user controls needs: the `voices` table default, the voice's `param_order`, `add_voice_params()`, `get_param_spec()`, a sender in `S.engine_senders`, and the exact case-sensitive name. Grain params go through `setGrainParam` and `GRAIN_PARAM_IDS`."

  It becomes: "...needs its default in the `voices` table, a place in the voice's `param_order`, a `get_param_spec()` spec and the exact case-sensitive name (the `synth` record adds and sends it); a grain param is a record's `grain_keys` entry."
- **Line 343** ("New params in `param_order` appear on the fader pages automatically") stays true, because the synth record's fader reads `param_order`.
- Line 189 is 1a's.

## 2. Names

**Renamed:** `M.add_voice_extra(voice_idx, record, key, param)` (`params_setup.lua:806`) becomes `M.add_voice_param(voice_idx, record, key, param)`. Its behavior is unchanged except where noted below; after 1a it stores into `S.voices[i].values[key]`.

**New export:** `M.turn_on_own_delta(key, param_id)`, today a local at `params_setup.lua:785`. The synth record's add calls it after each key (Risks 2).

**New and changed record fields.** Each is added to `VOICE_PARAM_FIELDS` and checked in `register_voice_params`.
- **`count`**: a whole number, or (new) `fn(voice_idx) -> whole ≥ 1`. The synth record needs the function form: resonator 7, fm 6, folder 5, sub 3, pulse, karplus and ring 6. There is a precedent: `scene_defaults` became a function in 3.7 (`state.lua:211-221`).
- **`voice_keys`**: voice-level sends, which go after `voiceOn` in a start.
  - Shape: `{key = "<engine name>" | {name, value = fn} | {send = fn(voice_idx, value)}}`, or `fn(voice_idx)` returning that table.
  - `add_voice_param` installs a gated sender for each key: `setVoiceParam(voice - 1, name, value)`, or the entry's own `send`.
  - Crossmod needs the `send` form: `setModSource`, `setModAmpAmt`, `setModFreqAmt` and `setModSpeed` are neither grain params nor `setVoiceParam`.
- **`send_order`**: an optional list of keys giving the order in which the record's grain or voice keys go out. The default is sorted, as `engine_sync.lua:702-703` does today.
  - The grain record needs it. Today's start sends size, density, pitch, spread, env, mode, buf_pos, buf_rate, buf_scan (`engine_sync.lua:724-733`); sorted order would differ.
  - So does crossmod: slot 1's source, amp and freq, then slots 2 and 3, then speed (`:745-751`).
- **`separator`**: optional.
  - A string is the text after `voice <i> `; `false` means no separator; nil means `"extras"`.
  - `add_voice_params` adds a separator before a record whose separator differs from the previous record's, outside the record's count window.
  - This reproduces today's menu exactly: synth `false`, grain `"granular"`, crossmod `"cross-modulation"`, and the 12 registered records nil, so one "extras" separator before the first of them (today's `:1189-1190`).
- **`fader`**: nil, `false` (kept, meaning none, so the 8 unchanged records need no edit beyond the rename), or a list of groups `{keys = {key, ...} | fn(voice_idx) -> keys, when = fn(voice_idx)}`.
  - A group's keys may name any key added for the voice, not only the record's own. This is needed; see "Why amp and pan sit in grain's fader groups" below.
  - At the end of `add_voice_params(i)`, every key a group gives for voice i (ignoring `when`) must be a param added for that voice, or init errors and names the record.
- **`main_randomize`**: a list of groups `{keys, when, draw = fn(voice_idx, key, param_id) -> value}`.
- **`mutate`**: a list of groups `{keys, when, chance = 1, scale = 1, warped = true|false}`.
  - `warped` true moves the value in the controlspec's normalized range (`mutated_value`).
  - `warped` false adds delta × scale and clamps to minval..maxval, as today's grain lines do (`mutation.lua:370-371`).
- **`action`**: I recommend not adding it. Every case the built-ins need is covered by a param filter or by the param table's own `action`, which `add_voice_extra` already runs last (`:820, 831`). See Risks 1.

**The three built-in records (proposal), registered in `lib/voices.lua` after `S.voices`.**

The **`synth`** record:
- `count = fn(v) #S.voices[v].param_order`.
- `add(v)`: for each key of `param_order`, a control with `get_param_spec(key)`, its default from 1a's static default for the voice, name `key`, formatter `VOICE_PARAM_FORMATS[key]`; then `turn_on_own_delta`. Move the drift and ratio formatters with the record, or export them.
- `voice_keys = fn(v)`, returning key→key for every key of `param_order`.
- `scene_defaults = fn(v)`, returning the voice's synth defaults.
- `separator = false`.
- `fader = {{keys = fn(v) param_order, when = voice_uses_synth}}`.
- `main_randomize = {{keys = param_order without amp, when = voice_uses_synth, draw = uniform over the controlspec}}`.
- `mutate = {{keys = param_order without amp and pan, when = voice_uses_synth, warped = true}}`.

The **`grain`** record:
- `count = 10`.
- `add`:
  - `source` is a plain `params:add` with today's action verbatim (`:944-970`). It is not a value (design §2 keeps `source` a field), and its action runs the source hooks, the sync and the fader-page clamp.
  - The nine grain params go through `add_voice_param`, with their specs moved verbatim.
  - `buf_pos` and `grain_pitch` set `S.buf_pos_base` and `S.grain_pitch_base` (unless `S.drift_writing`) in their own `action`.
- `grain_keys`:
  - grain_size `grainSize`
  - grain_density `{name = "grainDensity", value = function(x) return x * engine_param_value("master_density") end}`
  - grain_pitch `pitchShift`
  - grain_spread `posSpread`
  - grain_env `{name = "envShape", value = x - 1}`
  - grain_mode `{name = "grainMode", value = x - 1}`
  - buf_pos `bufPos`, buf_rate `bufRate`, buf_scan `bufScan`
- `send_order`: today's order.
- `discrete = {grain_env = {1, #GRAIN_ENV_OPTIONS}, grain_mode = {1, #GRAIN_MODE_OPTIONS}}`.
- `scene_defaults = fn(v)`.
- `separator = "granular"`.
- `fader` groups, in order:
  - `{keys = fn(v) {"buf_pos","buf_rate","buf_scan", unpack(voice_level_fader_keys(v))}, when = voice_uses_buffer}`
  - `{keys = {"grain_size","grain_density","grain_pitch","grain_spread","grain_env","grain_mode"}}`
  - `{keys = fn(v) voice_level_fader_keys(v), when = input}`, where input is `not voice_uses_synth(v) and not voice_uses_buffer(v)`.
- `main_randomize`, in order:
  - `{buf_pos uniform 0-1, buf_rate 2^(r*2-1), buf_scan r-0.5, when = voice_uses_buffer}`
  - `{grain_size r*0.3+0.05, grain_pitch r*2+0.5}`
- `mutate`, in order:
  - `{buf_pos, buf_rate, buf_scan, when = voice_uses_buffer, warped = true}`
  - `{grain_size chance 0.5 scale 0.2}`, `{grain_pitch 0.3 / 1.0}`, `{grain_spread 0.2 / 0.3}`, all `warped = false`.

The **`crossmod`** record:
- `count = 10`.
- `add`: per slot, mod_source (a number 0..NUM_VOICES with the `mod_source_text` formatter), mod_amp_amt and mod_freq_amt; then mod_speed. Specs verbatim from `:1130-1179`.
- `voice_keys` in the `send` form:
  - `setModSource(v-1, slot, S.lib.engine_sync.engine_mod_source(x))`
  - `setModAmpAmt(v-1, slot, x)`, `setModFreqAmt(v-1, slot, x)`
  - `setModSpeed(v-1, x)`
- `send_order`: today's order.
- `discrete = {mod_source_n = {0, NUM_VOICES}}`. Scenes switch the mod sources at a transition's end today (`scenes.lua:477`).
- `separator = "cross-modulation"`.
- `fader = {{keys = the nine slot keys}}`. mod_speed has no fader today.
- No `main_randomize` and no `mutate`.

**Why amp and pan sit in grain's fader groups.** Today's fader orders interleave the synth and grain keys (`faders.lua:45-58`):
- buffer: buf×3, amp, pan, then grain×6;
- input: grain×6, then amp, pan;
- synth: param_order, then grain×6.

Concatenating records in registration order reproduces all three only if the grain record may name the synth keys amp and pan. So `voice_level_fader_keys` stays as the helper. It is global (`faders.lua:33`), and its `params.pan` read becomes 1a's values read.

**`fader_param_ids(voice_idx)`** becomes a loop over `S.registry.voice_params` in registration order. For each record it takes each group of `record.fader or {}` whose `when` is absent or true, and appends `"v"..i.."_"..key` for each of the group's keys. `BUFFER_FADER_KEYS`, `GRAIN_FADER_KEYS` and `append_fader_ids` go.

**The new fader lines.** All are controls with a warp, and none spans 0, so none gets a zero column (`fader_zero_column` decides that from the range).

| Record | Line | Ids and ranges |
|---|---|---|
| voice_mix | `{keys = {"filter_freq","filter_res","filter_mix","delay_send","reverb_send"}}` | `v<i>_filter_freq` 20-20000 exp; `_filter_res` 0-1 lin; `_filter_mix`, `_delay_send`, `_reverb_send` 0-1 (`voice_mix.lua:128-138`). `filter_type` is an option, so it gets no fader |
| loops | `{keys = {"loop_start","loop_length"}, when = S.lib.loops.uses_buffer}` | `v<i>_loop_start` 0-1 lin, step 0; `_loop_length` 0.001-1 exp (`loops.lua:122-135`) |
| variation | `{keys = {"pitch_jitter","size_jitter","pan_jitter"}}` | 0-12 st lin, step 0.1; 0-1; 0-1 (`variation.lua:288-293`) |
| notes | `{keys = {"attack","release"}}` | exp 0.005-30 s and 0.01-30 s (`notes.lua:43-46, 911-913`) |

**Globals and names the tests reach:**
- `add_voice_params` and `get_param_spec` (globals in `MODULE_HOMES`, `structure_test.lua:421`) keep their names, as do `randomize_voice`, `gentle_mutate`, `fader_param_ids`, `fader_page_count` and `voice_level_fader_keys` (`:412, 441`).
- Tests reach `local_value("DISCRETE_GRAIN_KEYS")` (`mutation_test.lua:127, 327`), and `VOICE_SCENE_DEFAULTS` and `GRAIN_PARAM_IDS` (`params_setup_test.lua:43-46, 102, 326, 343-344`, and scenes_test). The last two are 1a's to settle.

## 3. Order and seams

1. **Registration order is the send, menu and fader order.**
   - The built-ins must be the first three records.
   - Records register in their module constructors, in include order. `history` is the first registered record today (strata.lua line 63, 17th in the include list).
   - `lib/voices.lua` is included at line 49, but `lib/params_setup.lua` only at line 109. So the records go in `lib/voices.lua` (which 2a owns), not in `params_setup.lua`.
   - The records' `add` functions call `S.lib.params_setup.*` and `get_param_spec` at init only, so this include order is safe.
2. **Seams with 1a.** 1a must leave these three in place, or 2a has to edit 1a's files.
   - **The sends.** `engine_sync.lua:698-711` (`send_registered_voice_values`) iterates `S.registry.voice_params` itself. Once the built-ins are records, it would send the grain keys a second time, in sorted order. 1a must route every record's sends through the one `params_setup.lua` function the design names (§2 "The start path").
     - The contract 2a needs from that function is two ordered phases. Before `voiceOn`: each record's `grain_keys` (in `send_order`), then its `sync`. After `voiceOn` and the grain-restart hooks: each record's `voice_keys` (in `send_order`). Bend (`:753`) stays in engine_sync, after them.
     - With the built-ins registered first, this is exactly today's start order (`:800-811`).
     - Today's sync order (`:765-768`: synth, grain, crossmod and bend, then the registered records) puts grain between two voice-level parts. 1a should define the sync as the same two phases. That changes the order for a running voice only; the design pins the start's order.
   - **The scene keys.** `scenes.lua:140-149, 315` (`registered_voice_scene_keys`, `fill_scene`) read every record's `scene_defaults` and `discrete`. 1a's fixed built-in scene lists must therefore sit behind a `params_setup` function too, or the built-ins' keys are counted twice once records exist. 2a's records carry `scene_defaults` and `discrete` (env, mode and the mod sources), and no `scene_ranges`.
   - **Static defaults.** 2a needs each voice's static defaults for every synth, grain and crossmod key (today `voices.lua:22-50` and its siblings). `values` holds live values, so `scene_defaults` and the param defaults must read a separate static table in `lib/voices.lua`.
3. **Files outside 2a's list.**
   - `lib/constants.lua` (the two dead key tables), `docs/user/grid/256.md`, and the notes of the four registering modules that gain faders.
   - `lib/pages/voice.lua:204` and `lib/pages/main.lua` need only 1a's values reads.
   - `VOICE_DRAWS` (`pages/voice.lua:177-192`) can stay: `row_draw` (`:197-206`) checks the records first, and VOICE's draws are unchanged.
   - No conflict with 2b inside wave 2: 2b edits `lib/engine_sync.lua` and `lib/lfos.lua`, which 2a avoids if the seam above holds.
4. **Must-not-break rules touched.**
   - AGENTS.md:250 is rewritten above.
   - `docs/notes/lua/loops.md:7` ("the 256 fader pages never touch them") must be rewritten.
   - The "Scale quantize" rule (AGENTS.md: "a voice's `quantize` loads ahead of its `freq` (`add_first`)") holds, because the add_firsts still run before every record's add.

## 4. Tests

**Re-base:** registries_test:176; voice_mix_test:268; loops_test:334; variation_test:596; mutation_test:118 and :320; grid_layout_256_test:11-25, :323-358 and :1138; voices_test:24-25; and every `add_voice_extra` call site (renamed).

**Today's lists, which the new tests must pin:**

| | synth voice | buffer voice | input voice |
|---|---|---|---|
| Faders | `param_order`, grain×6, crossmod×9 | buf×3, amp, pan (none on Sub), grain×6, crossmod×9 | grain×6, amp, pan, crossmod×9 |
| MAIN randomize | every synth key but amp, then grain_size and grain_pitch | buf_pos, buf_rate, buf_scan, then grain_size and grain_pitch | grain_size and grain_pitch |
| Mutate | the synth keys but amp and pan; grain_size, grain_pitch, grain_spread | buf×3; grain_size, grain_pitch, grain_spread | grain_size, grain_pitch, grain_spread |

**Page counts** (four faders a page). After, with the loop shown only on buffer voices: a synth voice adds 10 faders, a buffer voice 12, an input voice 10.

| Voice and source | Before | After |
|---|---|---|
| resonator, synth | 22 faders, 6 pages | 32, 8 |
| fm, pulse, karplus, ring, synth | 21, 6 | 31, 8 |
| folder, synth | 20, 5 | 30, 8 |
| sub, synth | 18, 5 | 28, 7 |
| buffer | 20, 5 | 32, 8 |
| sub, buffer | 19, 5 | 31, 8 |
| input | 17, 5 | 27, 7 |
| sub, input | 16, 4 | 26, 7 |

Without the loop's `when`, synth and input voices add 12 each, giving 7 to 9 pages: the design's figure.

**New tests:**
- `params_setup_test`, "the param list is 3.7.0's: ids, types, names, defaults, specs, options and separators, in order":
  - It compares `params.params` with a fixture. No param-list fixture exists: `test/fixtures/` holds only `3.6.0-files.lua` and `3.6.0-start-calls.lua`.
  - Record `test/fixtures/3.7.0-params.lua` from tag v3.7.0 by the start-calls fixture's method (its header, lines 9-18).
  - Each entry is `{id, t, name, default}`, plus `{min, max, warp, step, quantum, units}` for a control, `options` for an option, `min` and `max` for a number, and `string()` at the default for a param with a formatter.
  - 1a should record it (it is §11's "value table" test), and 2a must pass it untouched.
- `registries_test`:
  - "the built-in records come first: synth, grain, crossmod";
  - "a record's fader, main_randomize and mutate groups are checked" (refused: `fader = true`, keys that are neither a list nor a function, a `when` that is not a function, a missing draw, a `chance` outside 0-1);
  - "count may be a function of the voice, checked per voice";
  - "a fader key no record added for the voice refuses at init, naming the record";
  - "voice_keys and send_order are checked";
  - "records with one separator share it".
- `params_setup_test`:
  - "a voice's separators are today's: `voice i: name`, add_firsts, synth, `granular`, `cross-modulation`, `extras`" (the fixture covers this too);
  - "the PARAMS menu's own delta turns freq (filtered) but not expression's press target" (Risks 2);
  - "grain_env and grain_mode send envShape and grainMode x - 1, only while running";
  - "mod_source sends `setModSource` through `engine_mod_source`, whole, only while running";
  - "source reaches a stopped voice and clamps the fader page".
- `mutation_test`:
  - "MAIN's randomize draws 3.7's sets on every voice and source": compare `S.lib.mutation.voice_spec(v).draws` ids as sets with literal lists for synth, buffer and input on voices 1 and 4, and the buffer and grain order exactly.
  - "mutations reach 3.7's sets": probability 1 and amount 1; wrap `params.set` to collect the ids over 20 ticks; compare sets per source. Amp, pan, env, mode and source are never touched.
- `grid_layout_256_test`:
  - "each voice's faders are 3.7's then the new ones, per source": literal lists for voices 1 and 4 on synth, buffer 1 and input;
  - "the page counts per voice and source": the table above;
  - "the new faders follow their warp": attack column 1 = 0.005, column 16 = 30, column 8 exponential; filter_freq likewise;
  - "a loop fader appears only on a buffer voice";
  - "a source change to input clamps a page past the voice's last".
- `voices_test`, `grid_layout_128h_test`, `grid_layout_128v_test`: "the faders page reaches the last page": 8 page keys on row 5 (128h) or column 5 (128v), with the macro key still at column 16 or row 16.

## 5. Risks and open points

1. **The design's `action` example is already covered.**
   - The freq snap is a param filter (`variation.lua:221`, `S.register_param_filter("freq", ...)`), which `add_voice_extra` already runs (`params_setup.lua:827`).
   - The other special behaviors fit the param table's own `action`: the buf_pos and grain_pitch bases, quantize's snap, freeze's hooks.
   - The source param is the one that is not a value, and the grain record's add makes it with a plain `params:add`.
   - A record-level `action` field would add a second way to do the same thing. I recommend leaving it out, which drops one of the design's four new fields.
2. **`turn_on_own_delta` is applied only to the built-ins today** (`:936`), never to registered keys.
   - The filtered registered keys are expression's press and slide targets (`expression.lua:523`) and the loop's start and length (`loops.lua:66, 70`).
   - If `add_voice_param` applied it to every filtered key, a PARAMS-menu or `params:delta` turn of `press_target` would start stepping over `position` on synth voices (`expression.lua:443-448`). That is a behavior change.
   - Keep the call in the synth record's add only.
3. **Small send changes in the move.**
   - `grain_env`, `grain_mode` and `mod_source_n` call the engine directly today and skip `send_param_to_engine` (`:1097-1099, 1111-1113, 1141-1143`).
   - The generic action sends through it, so these sends become counted by the send budget, deferrable and recorded in `S.engine_param_values`.
   - `grain_mode` and `mod_source` also gain a `note_param_edit` call, which does nothing, since no randomize draws them.
   - The messages are the same. The plan should name this as accepted, or give `add_voice_param` a per-param opt-out (I see no need for one).
4. **VOICE's built-in sections interleave records too.**
   - The synth section holds the synth keys minus amp and pan (or the grain record's buf×3 for a buffer voice); mix holds source, amp and pan; crossmod lists `mod_speed` first (`voice_rows.lua:24-49`).
   - A record's `voice_rows` holds one section.
   - `first_field_row` (`:132`) runs from `ui/cursors.lua:19` at include time, before the registry may be read (AGENTS.md: registries are read at init or at use).
   - I recommend `section_keys` stays as it is (it is layout, not registration), and the built-in records carry no `voice_rows`. The design lists `lib/ui/voice_rows.lua` as 2a's, but there is nothing to change there beyond 1a's read.
5. **The design's order for the new faders cannot come from registration order.**
   - The records register as loops (strata.lua line 65), variation (66), voice_mix (67), notes (88).
   - Concatenating them gives loop, jitters, filter and sends, then attack and release. The design asks for filter, sends, loop, jitters, then attack and release (§7).
   - Option (a), my recommendation: accept registration order, with one line per record and no new field. The order is listed under "Calls made in this design", so the plan must say that it changed.
   - Option (b): give fader groups an optional `rank` that `fader_param_ids` sorts by, stably (built-ins 1-3, voice_mix 4, loops 5, variation 6, notes 7).
6. **The loop faders' `when`.**
   - The loop does nothing on synth and input voices (`docs/notes/lua/loops.md:13`), and VOICE hides its rows there (`loops.lua:142`).
   - With `when = uses_buffer`, voices have 7 to 8 fader pages, not the design's "7 to 9" (§7), which counts the loop on every source. I recommend the `when`.
   - Pan jitter on Sub (which has no pan) shows a fader, because VOICE shows its row. I did not check whether the engine pans a synth-source Sub's grains.
7. **`pairs` order in randomize and mutation.**
   - Today `voice_spec` (`mutation.lua:203`) and `mutate_voices` (`:329`) draw the synth keys in `pairs` order, as the start sends them.
   - The groups use `param_order`, so a seeded randomize lands differently per key; the sets are the same.
   - No test can pin today's order, because it differs between Lua and LuaJIT. State the change next to the start's new sorted order.
8. **`fader = false`.** Keeping `false` allowed means no edit to eight records. Dropping it re-bases `freeze_test.lua:65` and `scan_test.lua:344`.
9. **Unsure.** I could not establish whether 1a keeps `GRAIN_PARAM_IDS`, `VOICE_SCENE_DEFAULTS` and `DISCRETE_GRAIN_KEYS` (their test readers are listed above): 1a's fact file was not written when I looked.

# Package 3b: MIDI note off

## 1. Files

- `lib/midi_in.lua`:
  - header `:5-6` ("(auto: latch in the plain modes, release in the MPE modes)");
  - `:30-32`, the comment and `note_off_options = {"auto", "release", "latch"}`;
  - `:169-175`, `M.note_off_mode`: its comment and the `auto` line 173.
  - The readers `:199` (`release_held_notes`) and `:292` (`end_key`) are unchanged.
- `lib/params_setup.lua:713-721`: unchanged, since it reads `MIDI.note_off_options` with `default = 1`. Only a comment, if any.
- `lib/pages/setup.lua:62`: unchanged (it shows the param's own option string). `lib/mpe.lua` and `lib/expression.lua` read nothing of the setting (grep).
- **Docs:**
  - `docs/user/midi.md:19-23` (the auto bullet at line 22 and the 3.4 PSET sentence at line 23);
  - `docs/user/midi.md:25` ("under latch (auto, on a plain keyboard)") and `:27` ("(with auto, any MPE mode) ... So with auto, switching ... stops the voices they held");
  - `docs/user/params.md:114`;
  - `docs/notes/lua/midi.md:6`, a Must-not-break line ("`latch`, or `auto` in the plain modes" / "`release`, or `auto` in the MPE modes");
  - `docs/notes/lua/midi.md:52` (the option list and the PSET indices) and `:134` ("latch and release, auto"; "3.4's PSET indices").
  - `docs/user/pages/setup.md:10` and `docs/notes/lua/pages/setup.md:8, 28` stay.
- No AGENTS.md line names `auto`.

## 2. Names

- `S.lib.midi_in.MIDI.note_off_options` becomes `{"latch", "release"}`, default 1.
- `M.note_off_mode()` returns `MIDI.note_off_options[params:get("midi_note_off")]`, so its dependence on `S.lib.mpe.active()` goes.
- **Old PSETs:**
  - index 1 (`auto`) loads as `latch`;
  - index 2 stays `release`;
  - index 3 (`latch`) is clamped to 2, `release`, by norns' `Option:set` (`~/src/norns/lua/core/params/option.lua:39`, `util.clamp(math.floor(v), 1, self.count)`), as the design says.
- Nothing else is deleted: `auto` had no code but line 173.

## 3. Order and seams

The design's table gives 3b `lib/params_setup.lua`, but 3b needs no edit there: the param reads the options table. So 3b touches only `lib/midi_in.lua`, its tests and its docs. It does not need 2a and can run in any wave after 0a.

## 4. Tests

**The scratch run** (both edits applied): 2681 tests, 16 failures. Three come from the copy having no git (US spelling, tracked `.sc` files, guarded deletes). The 13 genuine failures:
- `midi_in_test.lua`:
  - "auto is latch in the plain modes and release in the MPE modes" (:903). Rewrite it as "the default is latch in every mode; release in every mode".
  - "mpe split: a note plays every voice whose zone and range hold it" (fails at :1054; relies on auto meaning release).
  - "a note off change releases every MIDI note, as a channel mode change does" (:1131).
  - "a port change, an unplug, a mode change and a panic release every MIDI note and empty the pool's count" (:1164).
  - "the layout hook acts only in the MPE modes, and a second run sends nothing" (:1313).
  - "RPN 6 with notes held ..." (:1411). It loops over `{1, 3}` as auto and latch; that becomes `{2, 1}`.
  - "a 3.4 PSET's channel mode and note off keep their behavior" (:1525). It becomes "a PSET's auto loads as latch, release stays, latch reads as release".
- `io_midi_out_test.lua`: the three shared-channel bend tests near :363, :382 and :410. They run in an MPE mode and rely on auto meaning release; set `midi_note_off` to 2.
- `io_system_test.lua`: "after that minute everything stops with no note left" (:1242).
- `strata_test.lua`: "3.5 end to end: a zone learn, an MPE chord on a buffer voice, ..." (:208).
- `pages_io_test.lua:157`: E3 from 2 to 3 now clamps at 2. Assert 2, or start from 1.

**Sets of 3 that pass only by clamping.** These set 3 to mean latch; it now clamps to release, so change them to 1: `midi_in_test.lua:913, 1156, 1201, 1266, 1279, 1287, 1310`. Also `:1761` loops `mode = 1, 3` (make it `1, 2`), and `strata_test.lua:459`'s `random(3)` becomes `random(2)`.

**New tests** (`midi_in_test.lua`):
- "midi_note_off offers latch and release, latch the default": a count of 2 and the two strings.
- "the note off mode is the option in every channel mode": modes 1-4 × both options.
- "an old PSET's note off: 1 loads latch, 2 release, 3 release": `params:set` with 3 reads `release`. Reading a PSET through the harness's pset helper would be better, if it has one (unsure).

## 5. Risks

- An MPE player's PSET saved with `auto` now latches after loading, and the player has to set `release` once. That is the design's §8. The user docs must say so where line 23 explains the 3.4 PSET today.
- I did not run the scratch change under LuaJIT.

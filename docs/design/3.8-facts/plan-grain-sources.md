# 3.8 plan facts: the grain's controls (1c), voices as sources (1d), the arpeggiator (2b)

Read against `main` at 2edbfa96. Line numbers are that commit's. The design is `docs/design/3.8-design.md` (§4, §5, §11, §12, §14), its facts `docs/design/3.8-facts/engine-grain.md`. Nothing here was run on the engine check. The Lua figures under "fader pages" come from a scratch probe that used the tests' harness (`scratchpad/plan-grain/count_test.lua`).

---

## Package 1c: the grain's controls

### 1. Files

Engine (1c owns them in wave 1):
- `lib/engine/StrataGrainDefs.sc`:
  - The grains area at 23-60 (`allocState` 26, the `envShape` handler 39-46, `free` 58).
  - `allocEnvelopeBuffers` and `freeEnvelopeBuffers` at 62-75 go.
  - Both literal `arg` lists at 107-120 and 150-163 gain the new controls.
  - Both `controls` Events at 124-135 and 172-183.
  - `grainSignal` at 223-263: the trigger at 242, the `vary` Event at 244-247, the two `GrainBuf`s at 253-256 (`c[\envBuf]`).
  - The header comments at 1-5 and 77-101.
- `lib/engine/StrataVariation.sc`: `grainRate` at 36-51 takes the arpeggiator step (the pick at 44, `Select.kr` at 45). The header comment is at 17-35.
- `lib/engine/StrataVoices.sc`, which is 0c's file in wave 0. No wave-1 package owns it, but the type packages 1f-1j add lines to its `voiceTypeDefs`. 1c changes:
  - `envBufnumFor` at 264-270 goes.
  - `engineOwnedControls` at 314-318 gains `\windowBank`. The comment at 296-313 changes.
  - The header comment at 5 and the `setGrainParam` comment at 155.

Tests and test harness:
- `test/norns_stubs.lua`, 0c's file:
  - The comment at 293-294.
  - The `envBuffers` enumeration parse at 551-555.
  - The `need(spec.enumerations.envShape, ...)` at 585 goes.
- `test/engine_check/grains.scd`:
  - The four-envelope checks at 447-476 are replaced by the bank's checks.
  - 352 (`\envBuf` among the kept controls).
  - 538 (`\envBuf, rectEnv.bufnum`).
  - 555 (`[\envShape, 0]`).
- `test/engine_check/variation.scd`: new checks for probability, overlap and the arpeggiator. 90 sets `\envBuf, rectEnv.bufnum`.
- `test/engine_check/memory.scd`: the grain limit at 139-142 (`size < 88`).
- `test/engine_check/structure.scd`:
  - 86 (`target.envBuffers ++ ...`) fails on nil once the variable is unset. It must become the bank (`target.areaState[\grains][\windowBank]`).
  - 499 ("free frees the envelope buffers").
- `test/engine_check/lifecycle.scd`:
  - 349, 370 (`envBuf == engine.envBuffers[0].bufnum`), 611, 618 and 622 use `envShape` and `envBuffers`.
  - 809 sends `[\setGrainParam, voice, \envShape, 0.0]`.
- `test/engine_check/voices.scd`: 378-407 (the envBuf keep check, which reads `engine.envBuffers`), 873 and 892 (`[\envShape, 1]`).
- `test/engine_check/notes.scd`: 517, 533 and 547 (`\envShape, 2.0` and `envBuf == engine.envBuffers[1].bufnum`).
- `test/engine_check/buffers.scd:406` and `test/engine_check/mix.scd:18` (`\envShape, 0` in the neutral lists).
- Grain synths' `\envBuf` set by hand, for rectangular-envelope timecode checks:
  - `test/engine_check/freeze.scd:113` and `test/engine_check/rings.scd:152` and `450`. Those two areas are 1d's.
  - Also `grains.scd:538` and `variation.scd:90`.
  - These need `envBuf` kept as an override (Risk 2).
- The check-only copies of the 3.2 and 3.3 defs:
  - `test/engine_check.scd:172-283`, whose `grainBody32` calls `e.grainRate` with a `vary` Event that has no arpeggiator keys (188).
  - `test/engine_check/modulation.scd:100-190`, whose `grainSignal33` calls `engine.grainRate` the same way (114).
  - `test/engine_check/mix.scd:37-70` calls `engine.grainSignal(c, reader)` with its own control Event at 47-62. That Event has no window, probability, overlap or arpeggiator key.
  - If 1a deletes `addSplitReferences` (the plain-sends package removes the 3.0-chain checks), only the first two remain.

Lua:
- `lib/grain.lua` **(new)**: `S.lib.grain`, one registered record.
- `strata.lua`: one include line. I propose it right after `S.lib.voices` (line 49), so the record is the fourth registered. It must come before any module that reads `S.lib.grain` at include time; none does.
- `lib/voices.lua` (the grain record, 1c's):
  - `grain_env = 1` in each voice's values: 7 sites, at 40, 70, 99, 126, 156, 186 and 216.
  - `GRAIN_ENV_OPTIONS` at 278.
  - `add_param(... "grain_env" ...)` at 416-417.
  - The `grain_keys` entry at 426.
  - `send_order` at 432.
  - `discrete` at 434.
  - The fader group at 437.
  - `count = 10` at 364 becomes 9.
  - The comment at 347-354.
- `lib/constants.lua`: `GRAIN_ENV_OPTIONS` at 55-58 and the export at 314.
- `lib/ui/voice_rows.lua:18`: `GRAIN_KEYS` loses `grain_env`. This is 0d's file in wave 0, and 3b's `preset` row comes in wave 3.
- `lib/pages/voice.lua:185`: `VOICE_DRAWS.grain_env` goes. This is 0d's file.
- `lib/engine_sync.lua`: only if the master density reaches `grainOverlap` from Lua (Risk 4, option a). The master density's sender is at 535-541 and its budget count at 143-149. No wave-1 package owns this file.
- `test/helpers.lua:699`: `scramble_state` sets `v<i>_grain_env` with `math.random(1, 5)`. Keep one random draw in its place, or every later draw of every seeded test moves.

Unit tests touched (`grep -rn grain_env test/unit` gives 70 lines in 13 files; GRAIN_ENV_OPTIONS appears in 2 more):
- `arc_core_test.lua:78`
- `arc_pages_test.lua:622`, `630`, `747-754` (a ring stepping the envelope option)
- `mutation_test.lua:12`, `136-139`, `670`, `935`
- `pages_voice_test.lua:140`, `449-468`, `846`
- `grid_layout_256_test.lua:21-22`, `54-64`, `1584`
- `engine_sync_test.lua:42`, `222-235`, `1040-1043`, `1057`, `1691` (`GRAIN_PART`)
- `params_setup_test.lua:34-73` and `1169-1184`
- `ui_detent_test.lua:124-125` and `170`
- `ui_cursors_test.lua:76` and `111`
- `scenes_test.lua`:
  - 1102
  - 1313-1322
  - 2105 (`REFERENCE_GRAIN_KEYS`)
  - 2209 (`REFERENCE_DISCRETE_KEYS`)
  - 3798
- `docs_test.lua`:
  - 146-154 (the commented-out `Env` patch)
  - 199, 204-205
  - 669-671
  - 761-765
- `stubs_test.lua:1303` and `1328`

Fixtures:
- `test/fixtures/3.7.0-params.lua` holds `v<i>_grain_env` at 514, 597, 679, 759, 842, 925 and 1008. It stays as 3.7.0 recorded it. The difference is listed in `params_setup_test.lua`'s `PARAM_FIXTURE_ALLOWED` at 1007-1016.
- `test/fixtures/3.7.0-start-calls.lua` has `setGrainParam(v, "envShape", 0)` at 28, 98 and 164.
- `test/fixtures/3.6.0-start-calls.lua` has 7 lines, at 26 and every voice after it.
- `test/fixtures/groundwork-files.lua` and `3.6.0-files.lua` hold old `grain_env` values. They stay as read fixtures (Risk 8).

Notes and user pages:
- `docs/notes/lua/grain.md` **(new)**, opening with "Must not break".
- `docs/notes/engine/grains.md` (15, 16, 18, 30 and 41 name `envShape` and `envBuf`).
- `docs/notes/engine/variation.md` (the 88 KB line at 4).
- `docs/notes/engine/memory.md` (10 and the 88 KB table rows).
- `docs/notes/engine/structure.md:150` (the four `envBuffers`).
- `docs/notes/engine/notes.md` (9 and 100).
- `docs/notes/engine/voices.md` (7 and 8).
- `docs/notes/test-harness/engine-stub-and-sync.md` (14 and 28).
- `docs/notes/lua/engine-sync.md` (114, 139 and 140: the grain part's nine entries become eight).
- `docs/notes/lua/params.md` (8 and 20).
- `docs/notes/lua/scenes.md:350`.
- `docs/notes/lua/state-and-voices.md` (23 and 36).
- `docs/notes/lua/ui/field-list-and-cursors.md:19`.
- `docs/notes/lua/pages/voice.md:33`.
- `docs/user/voices-and-grains.md:88` (the envelope bullet becomes the new controls).
- `docs/user/pages/voice.md` (10 and 46).
- `docs/user/params.md:162`.
- `docs/user/modulation.md:35` (the destinations gain `shape` and `skew`).

`AGENTS.md` (7744 words):
- Line 150, the `setGrainParam` row (55 words). "`envShape` index" becomes "`windowShape` 0-1 and `windowSkew` -1..1, `grainProb` 0-1, `overlapOn` 0/1, `grainOverlap`" (about +12 words). 1d adds its `inputChannel` here too.
- Line 214, "every grain synth under 88 KB" (92 words): the measured limit replaces 88. 0b first rewrites this line for the voice-def limit.
- Line 233, "Grain draws latch per grain" (41 words): add "the window pick latches with the grain (`GrainBuf`'s envelope number); probability gates the held trigger; the arpeggiator's step counts gated triggers" (about +20 words), or leave the line and put the detail in variation.md.
- The module table: one row for `lib/grain.lua` (about 8 words), after the `lib/voices.lua` row at 103.

### 2. Names

Engine (both grain defs, literal `arg` lists, neutral at their defaults):

| Control | Default | Meaning |
|---|---|---|
| `windowShape` | the Lua default (Risk 1) | 0-1, rounded to one of 8 shapes |
| `windowSkew` | 0 | -1..1, rounded to one of 15 skews (index 7 is skew 0) |
| `windowBank` | the bank's first bufnum | engine-owned, a named control like `fastModIn`; Risk 2 |
| `envBuf` | -1 | kept and engine-owned: below 0 plays the pick, 0 or above overrides it (check-only) |
| `grainProb` | 1 | 0-1; a draw gates the held trigger; triggered mode always passes |
| `overlapOn` | 0 | 0/1, written `overlapOn.round.clip(0, 1)` so the stub reads it as an enumeration |
| `grainOverlap` | 2 | 0.25-16; the rate is `grainOverlap / grainSize`, size after `fastMod`, clipped to 0.1-250 |
| `arpOn` | 0 | 0/1, written `arpOn.round.clip(0, 1)` |
| `arpFold` | 0 | 0/1, written `arpFold.round.clip(0, 1)` |
| `panSpread` | 0.5 | exists already; Lua sends it now |

- **New methods.** In `StrataGrainDefs.sc`:
  - `windowShapes { ^8 }`, `windowSkews { ^15 }` and `windowFrames { ^1024 }`.
  - `windowHannIndex` (shape h × 15 + 7).
  - `windowBank { ^areaState[\grains][\windowBank] }`.
  - `allocWindowBank` and `freeWindowBank` (the grains area's `allocState` and `free`).
  - `windowPick { arg c, mode; ... }`, which returns the envelope number `grainSignal` passes to both `GrainBuf`s.
- **The bank**, `areaState[\grains][\windowBank]`, is an Array of 120 consecutive Buffers:
  - Allocate it with `Buffer.allocConsecutive(120, server, 1024, 1, completionMessage: { arg buffer, index; buffer.setnMsg(0, tables[index].asArray) })`.
  - The `/b_setn` must ride as the completion message: a bare `setn` right after `/b_alloc` can arrive before the async allocation completes.
  - It is 491,520 bytes (480 KB), the window term 0b puts in `fixedBufferBytes`.
  - Set `grainControls[voice][\windowBank]` for every voice in `allocWindowBank`. `grainControls` exists from the voices area's `allocVoiceState` (`StrataVoices.sc:41`; order 20 < 30). `voiceOn`'s `putAll` keeps it.
- **The arpeggiator step**, in `grainRate` (StrataVariation.sc 36-51):
  - The code: `c = count.max(1); span = Select.kr(arpFold, [c, (2c - 2).max(1)]); s = Stepper.ar(trig, 0, 0, span - 1); index = Select.ar(arpFold, [s, (c - 1) - (s - (c - 1)).abs]); step = (index + 1) * (count > 0)`.
  - Then `pick = Select.ar(arpOn, [today's pick, step])`.
  - Use a `Stepper`, not the prototype's `PulseCount`: a float `PulseCount` stops counting at 2^24 grains (23 hours at 200 a second), and `mod` of it then repeats one step.
  - With `vary[\arpOn]` nil (the check-only copies), build today's graph unchanged.
- **Probability**, after the `Trig1` at 242: `trig = trig * (TRand.ar(0, 1, trig) < grainProb.max(mode))`. In triggered mode (mode 1) the comparison always passes.
- **Overlap**, at 242: `Impulse.ar(Select.kr(overlapOn.round.clip(0, 1), [c[\grainDensity], (c[\grainOverlap] / c[\grainSize]).clip(0.1, 250)]))`. `c[\grainSize]` is the size after `fastMod` (offsets and `noteSize`), before the per-grain size jitter. The design says "after every modulation of the size": the jitter is a per-grain draw, so it cannot set the rate.
- **Removed**: the `envShape` handler (StrataGrainDefs.sc:39-46), `envBufnumFor` (StrataVoices.sc:266-270), `allocEnvelopeBuffers` and `freeEnvelopeBuffers`.
  - `var <envBuffers` in `lib/Engine_Strata.sc:28` stays: that file is never edited. Leave it nil and say so in a comment in StrataGrainDefs.sc.
  - Every check that reads `engine.envBuffers` must change (list above).

Lua (`lib/grain.lua`, `S.lib.grain`):
- One table, `M.GRAIN = {section = "grain", keys = {...}, clouds = {"density", "overlap"}, cloud_index = {density = 1, overlap = 2}, percent = 100, shape_default = <h / 7>, overlap = {min = 0.25, max = 16, default = 2}, lfo = {{label = "shape", key = "grain_shape"}, {label = "skew", key = "grain_skew"}}}`.
- One record, `S.register_voice_params{name = "grain_controls", ...}`. "grain" is taken by the built-in record.

| Param | Type and spec | Default | Engine (`grain_keys`) |
|---|---|---|---|
| `v<i>_grain_shape` | control 0-1, lin, step 0.01 | h/7 (Risk 1) | `"windowShape"` |
| `v<i>_grain_skew` | control -1..1, lin, step 0.01 | 0 | `"windowSkew"` |
| `v<i>_grain_prob` | control 0-100 %, lin, step 1 | 100 | `{name = "grainProb", value = x / 100}` |
| `v<i>_grain_cloud` | option {density, overlap} | 1 | `{name = "overlapOn", value = x - 1, carry = false}` |
| `v<i>_grain_overlap` | control 0.25-16, exp | 2 | `{name = "grainOverlap", value = ...}` (Risk 4) |
| `v<i>_pan_wander` | control 0-100 %, lin, step 1 | 50 | `{name = "panSpread", value = x / 100}` |

The rest of the record:
- **`count = 6`.**
- **`send_order`**: the six in the table's order.
- **`scene_defaults`**: the six defaults.
- **`discrete = {grain_cloud = {1, 2}}`.**
- **`scene_ranges`** for the five continuous keys.
- **`voice_rows`**: `{section = "grain", rows = {shape, skew, prob, cloud, overlap, pan_wander}, when = fn}`. The `when` hides `grain_overlap` in density mode. Hiding `grain_density` in overlap mode needs `lib/ui/voice_rows.lua` (Risk 5).
- **`fader = {{keys = {"grain_shape", "grain_skew"}, rank = 0}}`** (Risk 6).
- **No `main_randomize`, `mutate` or `randomize`.** The record draws nothing.
- **`layout_states`**: each voice at both ends of each new row.
- **LFO destinations**: `S.register_lfo_destination("shape", "grain_shape")` and `S.register_lfo_destination("skew", "grain_skew")`, which give "v<i> shape" and "v<i> skew".
  - They are matrix destinations too (`lib/matrix.lua:130` reads `S.LFO_DESTINATIONS`).
  - They are macro targets with no further call: `lib/macros.lua:94-104` adds every control destination.
  - Neither is a fast destination: the matrix sums them in Lua (`set_extra_offset`).
- **Accessors** for VOICE, MAIN and the faders: `M.overlap(voice_idx)` (whether the cloud is overlap) and `M.shape_text` and `M.skew_text` (formats).
- **No globals.** `MODULE_HOMES` is unchanged.
- **Tests reach it** through `S.lib.grain.GRAIN`, so `local_value` is not needed.

Scene format 10 (0d raises it). 1c adds six registered voice keys: `grain_shape`, `grain_skew`, `grain_prob`, `grain_cloud` (discrete 1-2), `grain_overlap` and `pan_wander`. `grain_env` leaves the built-in keys: the grain record's scene keys are every key it adds.

### 3. Order and seams

- **Needs from 0d** the format-10 scene layer. The `grain` built-in record must still exist in `lib/voices.lua` after 0d; 0d rewrites the `synth` record, not `grain`.
- **Needs from 0b** `fixedBufferBytes`, with the bank's 491,520 bytes as one of its terms. 1c adds a check that the bank holds exactly `windowShapes × windowSkews × windowFrames × 4` bytes. 0b must state its term in those names, or the two drift.
- **Gives 2b** `arpOn`, `arpFold` and the `Stepper` step on `interval1..intervalCount`. 2b sends them; 1c only declares and implements them.
  - The design splits the arpeggiator in two. The counter and the fold are 1c's def edits: `grainRate` and the arg lists, owned files `StrataGrainDefs.sc` and `StrataVariation.sc`. The Lua ordering, the chord path and the option param are 2b's.
  - Between the two landings the controls sit at 0 and nothing sends them.
- **Gives 3b** the six keys for `VOICE_PRESETS.keys`: all "in" (§8.1).
- **Shared files in wave 1**:
  - `lib/constants.lua` (1c removes `GRAIN_ENV_OPTIONS`, 1d adds `SOURCE_*`).
  - `test/norns_stubs.lua` (1c removes the `envShape` parse, 1d widens `setGrainSource`).
  - `test/engine_check/structure.scd:80-87` and `499` (1c the bank, 1d the out rings; 1b and 2a may add delay and shimmer buffers).
  - `test/engine_check/memory.scd` (1c the grain limit; 1d its voice-source cases; 1f-1j their limit lines).
  - The `setGrainParam` row of `AGENTS.md` (1c and 1d).
  - All are line-level, and 1c lands before 1d.
- **AGENTS rules it rewrites**: the grain limit's figure (line 214, after 0b) and the `setGrainParam` row (150). The notes' Must-not-break lines:
  - `variation.md:4` (88 KB).
  - `grains.md` "Both grain SynthDefs declare every grain control with a literal arg list ... the 3.2 controls default to 3.1's sound". The new controls must be neutral at their defaults.
- **The whole-system tests.** They compare a start with 3.7.0's calls: `engine_sync_test.lua:1653-1676` against `test/fixtures/3.7.0-start-calls.lua`, and `system_37_test.lua:85-145` against `3.6.0-start-calls.lua` with `NEW_SYNC_KEYS`.
  - 1c changes every voice's start: `envShape` goes, and six setGrainParam (`windowShape`, `windowSkew`, `grainProb`, `overlapOn`, `grainOverlap`, `panSpread`) come.
  - §13 says the last package of each wave re-bases once. But every package's branch must pass on its own, so 1c needs its own allowance there (Risk 9).

### 4. Tests

To re-base:
- **`params_setup_test.lua`**:
  - The tests at 30-73 (grain_env is an option of 5, its scene range 1..5, its migration) become tests of `grain_cloud` or go to grain_test.
  - 1169 ("grain_env and grain_mode send envShape and grainMode x - 1") keeps grain_mode only.
  - The fixture comparison gets entries.
- **`PARAM_FIXTURE_ALLOWED`** has kinds `removed`, `group_size` and `options` only (`params_setup_test.lua:996-1016`). New params break its index-by-index comparison. 0d adds 252 synth params and must add a kind `added`. 1c then adds 7 × `removed v<i>_grain_env` and the six `added` per voice.
- **`grid_layout_256_test.lua:15-24`**: "fm has 31 faders ... 8 pages" and `ids[11] == "v2_grain_env"`; also 54-64 (the envelope fader) and 1584 (`GRAIN_FADERS`).
- **`scenes_test.lua` 2105 and 2209**: the reference key lists.
- **`engine_sync_test.lua:1691`**: `GRAIN_PART` loses `envShape`.
- **`docs_test.lua` 204-205, 669-671 and 146-154**: the `envShape` enumeration. Replace them with `overlapOn`, `arpOn` and `arpFold` enumerations (0..1) and rejections of `overlapOn` 2 and 0.5.
- **`stubs_test.lua:1303` and `1328`.**

New unit tests, in `test/unit/grain_test.lua` (new, one file per module):
- "the six grain params, their specs and defaults". Shape 0-1 at h/7, skew -1..1 at 0, prob 0-100 at 100, cloud {density, overlap} at 1, overlap 0.25-16 exp at 2, wander 0-100 at 50; their formats at both ends.
- "a running voice sends windowShape, windowSkew, grainProb x/100, overlapOn x-1, grainOverlap and panSpread x/100; a stopped one only stores".
- "a start sends the six before voiceOn, in send_order".
- "the cloud: density mode shows grain_density and hides grain_overlap on VOICE, overlap mode the reverse".
- "shape and skew are LFO, matrix and macro destinations ('v1 shape', 'v1 skew'); an LFO on them sends windowShape and never sets the param".
- "the fader pages: shape and skew after <whatever rank 0 gives>; no grain_env fader".
- "no randomize, mutation or drift moves the six".
- "a scene captures and recalls the six; grain_cloud switches at a fade's end; shape fades".
- "grain_env is gone: no param, no scene key; a 3.7 PSET's v<i>_grain_env lines load without error".
- The layout states for each row at both ends of its range.

Engine checks:
- **grains area:**
  - "the window bank: 120 tables of 1024 frames, consecutive bufnums, built in under 50 ms with Signal primitives; each table finite, at most 1 and at least 0, zero at both ends (or as the families give)".
  - "grain synths start with windowBank = the bank's first bufnum".
  - "at windowShape h/7, windowSkew 0 the grain plays GrainBuf's Hann", proved by the equality checks below.
  - "a non-default pick reads the table it names": for each corner (shape 0 and 1, skew -1 and 1), the output's envelope against the table's, with a long grain on a DC ring.
  - "windowBank, envBuf are refused by setGrainParam".
  - "the bank's bytes equal fixedBufferBytes' window term".
- **variation area:**
  - "grainProb 0: no grain in continuous mode; triggered mode still sounds a retrigger".
  - "grainProb 0.5: 40-60 % of triggers over 2 s at density 200".
  - "overlapOn 1, grainOverlap 2, size 0.1: 20 triggers a second (±1 over 2 s); size 0.01, overlap 16: 250 a second; size modulated by a fast offset: the rate follows".
  - "arpOn 1, count 3, intervals 0, 12, 24: successive grains' rates cycle 1, 2, 4 (the one-grain lag allowed)".
  - "arpFold 1: 1, 2, 4, 2, 1, ..."; "arpOn 0: today's draw (rates among the set at random)".
  - "a dropped grain does not advance the step".
- **The equality checks against 3.2 and 3.3** (`test/engine_check.scd`, `modulation.scd`; `mix.scd` if it survives 1a) still hold at the new controls' defaults. Each new term is exactly neutral there: `envBuf` -1 from the pick, `trig × 1`, `Select` of density, today's pick. The copies' `vary` Event has no arpeggiator keys, so `grainRate` must build today's graph when they are nil.
- **memory area:**
  - Measure both defs with the four additions on 3.13 and 3.14.1.
  - Set `size < limit` at 140 with limit = the larger reading + 2 KB, rounded up, at most 97. The design estimates about 90.2 KB for `\strataGrainBuf`.
  - Re-read every worst case. The tightest high case's arithmetic in §1 counts -165 KB for the grain additions on 21 grain synths.
  - Read the logs for `alloc failed` (the facts' §0.5: a case near its floor reads optimistic).
- **Shards**: none new. grains and variation are both in `mix,variation,grains,structure,performance`.

### 5. Risks and open points

1. **The default shape must land on a table exactly.**
   - With 8 shapes, no value is a center. The Lua default `grain_shape` must be k/7 for the Hann's shape index k, and the pick must round (`(shape × 7).round`).
   - The builder picks the families (left to it in the design). The default must make `windowShape` round to h, and `windowSkew` 0 to index 7.
   - Compare with `BinaryOpUGen('==', index, hannIndex)`. In sclang, `ugen == number` is a Boolean (AGENTS' `\strataFilter` rule, true of any UGen).
   - Unsure: whether a table Hann sounds the same as `GrainBuf`'s internal one. That does not matter, since the default plays -1.
2. **The checks set `envBuf` by hand** (rectangular envelopes for timecode reads) at 5 sites in 4 areas, two of them 1d's: `grains.scd:538`, `variation.scd:90`, `freeze.scd:113`, `rings.scd:152` and `rings.scd:450`.
   - If `envBuf` stops being a def control, those checks silently play the pick.
   - Keep `envBuf` as an engine-owned override (≥ 0 wins). The prototype's `protoWindowPick` already selected between `envBuf` and the bank, inside its measured 2.5 KB.
3. **A def default can lose the bank.**
   - The bank's bufnum baked in as a def default is what a second engine replaces: "SynthDefs are named per server", `docs/notes/engine/variation.md:7` for `scaleBuffer`. The engine check builds second engines often.
   - With `windowBank` sent explicitly in `grainControls`, a grain synth of `h.engine` never reads a freed bank.
4. **The master density in overlap mode** ("Master density scales the rate in both modes", §4.4). The engine sees the master density only inside `grainDensity`. Choose one:
   - (a) `grainOverlap` is sent × `master_density`, and `send_master_density_to_engine` (`lib/engine_sync.lua:535-541`) sends each running voice `grainOverlap` in overlap mode in place of `grainDensity`. The budget count at 143-149 stays one per running voice.
   - (b) A per-synth `masterDensity` control, and a second message per voice.
   - Recommended: (a). It edits `lib/engine_sync.lua`, which no wave-1 package owns.
5. **The design's VOICE layout cannot be built from 1c's record alone.**
   - "overlap takes the density's row" and "the cloud mode with density or overlap under it" (§4.4, §12) need the built-in grain section to drop `grain_density` while the cloud is overlap.
   - The registered rows' `when` filters only the record's own rows, so `lib/ui/voice_rows.lua:18-26` changes (0d's file).
   - The design is silent on whether MAIN's third field and arc ring 4 (`grain_density`, `lib/pages/main.lua:114-119`, `lib/arc/main.lua:34`) follow the cloud. In overlap mode they edit a param that does nothing.
6. **The fader place.**
   - A rank-0 group in `lib/grain.lua` sorts after the crossmod record's nine rank-0 faders (`lib/grid/faders.lua:35-57`: stable, by rank, then registration), not where `grain_env` sat (5th of the grain group).
   - To sit there exactly, the built-in grain group (`lib/voices.lua:437`, 1c's) lists `grain_shape` and `grain_skew` itself; a group's keys may be any key of the voice (`lib/state.lua:278`). The grain.lua record then carries `fader = false`.
   - Either way the counts move: today resonator 32 faders / 8 pages, fm 31/8, folder 30/8, sub 28/7, each buffer voice 32/8 (31 for sub), input 27/7 (probe).
   - After 1c: resonator and every buffer voice 33 → **9 pages**, sub 29/8. 0d's per-type keys and 1f-1j's types (noise has 8 synth keys) add more.
   - §10.4's faders page has eight page keys (`p1`-`p8`, columns 1-8, the bank keys at 10-13). That is 1k's problem, but 1c triggers it.
7. **`scramble_state`** (`test/helpers.lua:688-705`) draws `math.random(1, 5)` for `grain_env`. Removing the line shifts every later draw in every seeded test. Keep one draw: set `grain_shape` from it.
8. **Old files.** The read fixtures (`3.6.0-files.lua`, `groundwork-files.lua`) hold `grain_env` values. 0d's format floor sets those scenes aside. Their PSET lines name no param: `system_37_test.lua`'s `PSET_3_6.drops` (around 165) needs a `v<i>_grain_env` entry, as `strata_pset_format` has.
9. **The start fixtures.** `engine_sync_test.lua`'s "a voice start sends 3.7.0's messages" takes no allowance today. 1c (and 1d, 2b after it) needs a list of allowed differences there, as `PARAM_FIXTURE_ALLOWED` is for params, or it cannot pass on its own branch.
10. **The prototype's `Select.kr` lag** (`variation.md:3`): an arpeggio plays in order, one grain late. Accepted in the facts; nobody has listened to it (facts' Unsure).

---

## Package 1d: voices as sources, and the input channel

### 1. Files

Engine (1d's):
- `lib/engine/StrataOutRings.sc` **(new)**: area `strataAreaOutRings`, state `areaState[\outRings]`, order **135** (free between record 130 and waveform 140).
  - Start runs ascending, so the record area's `start` (`StrataRecord.sc:182-194`) has made `tapGroup` first.
  - Stop runs descending (`docs/notes/engine/structure.md:168`), so the writers are freed before the record area's `stop` frees the tap group (`StrataRecord.sc:196-202`).
  - `structure.md:168` lists the orders: add 135.
- `lib/engine/StrataUtil.sc:26-30`: `voiceSourceFirst` and `validSource`.
- `lib/engine/StrataRings.sc`:
  - `ringBuffersFor` at 61-67 gains a voice-source branch.
  - The rings area at 34-44 gains `grainParamHandlers: (inputChannel: ...)`.
  - The comments at 1-5, 25-33, 51 and 58-60.
- `lib/engine/StrataFreeze.sc`:
  - `frozenOnInput` 154-157.
  - `freezeVoice` 189-216 (the case at 208-215).
  - `unfreezeVoice` 226-246 (the case at 237-245).
  - `startCopyWriter` 336-342.
  - `copyInputToCopyRing` 367-391.
  - `inputHeadFrame` 394-401.
  - `copyInputSpan` 405-424.
  - `pointAtCopyRing` 439-445.
  - `readsInputCopy` 448-451.
  - `grainReadPairs` 460-474.
  - `returnToInputRing` 489-499.
  - The header comment at 1-15.
- `lib/engine/StrataNotes.sc`, 0c's file. No wave-1 package owns it:
  - `noteKindFor` at 153-159: a voice source is `\input`.
  - `perNoteGrainControls` at 218-224: a voice source adds `\pitchShift`.

Engine sites read and found right as they are (the predicate is "not 0 and not a slot", so a voice source behaves as the input):
- `StrataLifecycle.sc`: 43, 68-78 (the default branch gives `rateLevel 1` and `bufferSlotPairs` [] for sources 10-16), 82-85, 119, 149, 159, 223 and 329.
- `StrataMix.sc:46-48` (`voicePathBus`).
- `StrataGrainDefs.sc:31-34` (`grainDefs` falls through to `\strataGrainRing`) and 52-56 (the `history` handler, input only: a voice source has no history).
- `StrataFreeze.sc:161-166` (`freezeModeFor` allows spectral for any non-slot).
- `StrataScale.sc:45`.
- `StrataNotes.sc` 137, 479 and 573.
- `StrataVoices.sc:286`.

Tests and test harness:
- `test/norns_stubs.lua`, 0c's file:
  - `setGrainSource`'s check at 673 (`range("source", args[2], 0, spec.input_source)`).
  - A `voice_source_first` parse beside `input_source` at 448-449. Pattern: `voiceSourceFirst { ^numBuffers + N }`.
  - `need(...)` at 582.
  - The header at 257.
- `test/engine_check/lifecycle.scd:431-434`, 0c's area in wave 0: "out-of-range sources are ignored" sends 10 and -1. 10 becomes valid; send 17 (`voiceSourceFirst + numVoices`).
- `test/engine_check/outrings.scd` **(new)**, with `\outrings` added to `areaOrder` in `test/engine_check.scd:24-25`.
- `.github/workflows/test.yml:104-111`: a shard. Not `memory,rings`: memory shares with no area that builds a high engine, and a reader's spectral freeze needs one. So `modulation,freeze,envelopes,outrings`.
- `test/engine_check/structure.scd`:
  - The out rings' 14 buffers join the buffer list at 86-87.
  - The 7 phase buses join the bus list at 82-85.
  - The free checks at 495-505.
- `test/engine_check/memory.scd`: the voice-source worst cases (below).
- `test/engine_check/freeze.scd` and `rings.scd`: the reader's freeze and the input channel's read pairs. Or keep them all in `outrings.scd`.

Lua:
- `lib/constants.lua:65-74` and `316-318`: `SOURCE_VOICE_FIRST`, `SOURCE_OPTIONS` to 17, the comment at 65-67.
- `lib/voices.lua:229-248`:
  - `voice_uses_input` and `voice_uses_voice` (new globals).
  - `voice_source_voice` (new: the voice a voice source reads, 1-7, or nil).
  - `voice_source_label`.
  - The local `uses_input` at 284.
  - The comment at 1-8.
- `lib/history.lua`: the `v<i>_input_channel` param in its record (Names), `M.HISTORY` and the header at 1-9.
- `test/unit/structure_test.lua:402`: `MODULE_HOMES["lib/voices.lua"]` gains the new globals.
- User pages:
  - `docs/user/sources-and-buffers.md` (5, and a section on voice sources and loops, saying a loop holds at full scale).
  - `docs/user/pages/buffer.md`, `docs/user/pages/main.md` (`v2`) and `docs/user/pages/voice.md` (the channel row).
  - `docs/user/technical.md:11-17` and `57` (the signal flow).
  - `docs/user/arc.md:14-15`, `docs/user/modulation.md:35` and `40` and `docs/user/midi.md:16` and `23` ("input-sourced" means "input- or voice-sourced").
- Notes:
  - `docs/notes/engine/outrings.md` **(new)**.
  - `docs/notes/engine/rings.md` (Must not break, lines 3-11).
  - `docs/notes/engine/freeze.md` (lines 3-20).
  - `docs/notes/engine/structure.md` (4 and 164: node order; 168: orders).
  - `docs/notes/lua/state-and-voices.md` (the source tests) and `docs/notes/lua/history.md`.

### 2. Names

Engine:
- `voiceSourceFirst { ^numBuffers + 2 }` (10) in `StrataUtil.sc`, beside `inputSource { ^numBuffers + 1 }`.
- `voiceSource { arg source; ^source.isInteger and: { source.inclusivelyBetween(this.voiceSourceFirst, this.voiceSourceFirst + numVoices - 1) } }`.
- `readVoiceOf { arg source; ^source - this.voiceSourceFirst }`.
- `validSource`'s upper bound becomes `this.voiceSourceFirst + numVoices - 1` (16).
- Command `setGrainSource(voice, source)`, `"ii"`: the signature is unchanged and the range grows. The AGENTS row at 160 becomes:
  `| \`engine.setGrainSource(voice, source)\` | \`"ii"\` | 0 = synth, 1-8 = buffer slot, 9 = input, 10-16 = voice 1-7's output ring. Replaces a running voice's grain synth (never stacks), records a stopped voice's choice; same source = no-op |` (+6 words)
- `areaState[\outRings]`:
  - `\left` and `\right`: Arrays of 7 mono Buffers of `server.sampleRate * this.ringSeconds` frames.
  - `\phaseBuses`: 7 control buses, set 0.
  - `\writers`.
- Methods in `StrataOutRings.sc`:
  - `allocOutRings`, `addOutRingDefs` (returns []), `startOutRingWriters`, `stopOutRingWriters` and `freeOutRings`, each hook calling through `areaCall`.
  - `outRingWriterKeys` (`\outRingWrite0` .. `\outRingWrite6`, the area's `effectKeys`).
  - `outRingFor { arg voice; ^[left, right, phaseBus] }`.
- SynthDef `\strataOutRingWrite` (`arg in, bufL, bufR, phaseOut`): `\strataRingWrite`'s graph with `this.zeroBadValues(channel).softclip` on each channel.
  - Placement: `Synth(..., [\in, areaState[\record][\voiceTaps][v], \bufL, ..., \bufR, ..., \phaseOut, ...], areaState[\record][\tapGroup], \addToTail)`.
  - The prototype's writer with `clip2(1)` measured 5.06 KB. `softclip` must be measured again.
- `ringBuffersFor(voice, source)`: `{ this.voiceSource(source) } { ^this.outRingFor(this.readVoiceOf(source)) }`.
- `grainReadPairs(voice)` (`StrataFreeze.sc:460`): a voice source reads its copy ring at history 0 when it reads a copy (below), else `ringBuffersFor(voice, source)` at history 0.
  - The input source, its copy included, applies the channel: 0 `[L, R]`, 1 `[L, L]`, 2 `[R, R]`, from `grainControls[voice][\inputChannel] ? 0`.
- Grain param handler `inputChannel` (handler-only, in the rings area's `grainParamHandlers`):
  - It keeps `grainControls[voice][\inputChannel] = value.round.clip(0, 2)`. Write it on a variable named `inputChannel`, so the stub's `name.round.clip(low, high)` parse reads 0-2. Written on `value`, the stub would key the enumeration under `value`.
  - When the voice is on the input it sends `this.setGrainSynths(voice, *this.grainReadPairs(voice))`, as `pointAtCopyRing` does.
  - It returns true.
  - `controlPairs` drops it from `grainControlPairs`, since no def has that control.
  - A note started later gets the pairs through `grainControlPairs`.
- The freeze names are generalized. Each name is kept, with its meaning widened to "a ring another writer writes":
  - `frozenOnInput` becomes "frozen with a copy": source input or voice source.
  - `readsInputCopy`.
  - `copyInputToCopyRing(voice)` reads the frozen source's ring: `ringBuffersFor(voice, source)` and its phase bus.
  - `copyInputSpan(voice, head)` takes the source ring's frames, not `inputL`'s; history only for the input.
  - `returnToInputRing(voice)` sets back to `state[\source][voice]`'s ring, channel applied.
  - `pointAtCopyRing`'s guard at 441.
  - `inputHeadFrame` gains an argument, the phase bus: rename it `ringHeadFrame { arg bus; ... }` and update `test/unit/structure_test.lua:1446` (`AREA_CALL_METHODS`) and `docs/notes/engine/structure.md:7`. It is called through `areaCall` from the copy's fork, and stays that way.
  - Count of mentions if the others were renamed instead: `inputReaders` 11 lib, 10 test, 13 docs; `noteInputReader` 5, 0, 7; `pointAtCopyRing` 4, 0, 9. Renaming costs about 60 lines and buys nothing.
- `startCopyWriter(voice)`. For a voice source: `\in` is `areaState[\record][\voiceTaps][readVoiceOf(source)]`, target `areaState[\record][\tapGroup]`, `\addToTail`. For the input it stays `inputBus`, `voiceGroup`, `\addToTail`. Its keys stay `copyWriterKeys`.

Lua:
- `SOURCE_VOICE_FIRST = SOURCE_INPUT + 1` (11).
- `SOURCE_OPTIONS[SOURCE_VOICE_FIRST + j - 1] = "voice " .. j` for j = 1..NUM_VOICES. Option 17 is sent as `setGrainSource(v, 16)` by `S.lib.engine_sync.send_grain_source` (`lib/engine_sync.lua:569-571`), unchanged. Export `SOURCE_VOICE_FIRST`.
- `function voice_uses_input(voice_idx) return S.voices[voice_idx].source == SOURCE_INPUT end`.
- `function voice_uses_voice(voice_idx) local s = S.voices[voice_idx].source; return s >= SOURCE_VOICE_FIRST and s < SOURCE_VOICE_FIRST + NUM_VOICES end`.
- `function voice_source_voice(voice_idx)` returns 1-7 or nil.
- `voice_source_label(voice_idx)` returns `"v" .. j` for a voice source (MAIN's `v2`, §12; also BUFFER's source field, `lib/pages/buffer.lua:270`), else `SOURCE_OPTIONS[source]`.
- Param `v<i>_input_channel`: option {"stereo", "left", "right"}, default 1. I propose it in `lib/history.lua`'s record, whose VOICE section `input` already shows only on an input voice:
  - `count` becomes 2.
  - `grain_keys.input_channel = {name = "inputChannel", value = function(x) return x - 1 end, carry = false}`.
  - `scene_defaults.input_channel = 1`, `discrete = {input_channel = {1, 3}}`.
  - `voice_rows.rows = {"history", "input_channel"}`, `when = M.uses_input`.
  - `M.HISTORY.channel_key = "input_channel"`, `M.HISTORY.channels = {"stereo", "left", "right"}`.
  - The param goes in "voice <i> extras" after `v<i>_history`, so the fixture gets 7 `added` entries.
- **Scene format 10.** It adds the voice key `input_channel`, and a voice's `source` ranges 1-17. `lib/scenes.lua:1247` already reads `#SOURCE_OPTIONS`, so the range follows with no edit, whatever 0d does to that function.

**Every site in lib/ that tests a voice's source** (`grep -rn voice_uses_synth|voice_uses_buffer|SOURCE_INPUT|SOURCE_SYNTH|SOURCE_OPTIONS|voice_buffer_slot|voice_source_label|source ==|source >|source <|source ~=` over lib/ and strata.lua, less lib/engine/):

| file:line | What it assumes | For a voice source |
|---|---|---|
| `lib/voices.lua:230-237` | synth, slot, else input | add `voice_uses_input`, `voice_uses_voice` and `voice_source_voice` beside them |
| `lib/voices.lua:239-241` `voice_source_label` | the option's name | return `v<j>` |
| `lib/voices.lua:245-248` `voice_buffer_slot` | slot only | right as is |
| `lib/voices.lua:284` local `uses_input` = not synth, not buffer | input | rename `uses_ring` (`voice_uses_input(i) or voice_uses_voice(i)`): a voice source gets the level faders (the grain record's third fader group, 1c's lines 436-439) |
| `lib/notes.lua:128` `frozen_synth` | synth only | right |
| `lib/notes.lua:177` `ends_at` | buffer only | right |
| `lib/notes.lua:368-369` `own_pitch` | else = grain_pitch (input) | right; comment "an input or voice-source voice" |
| `lib/notes.lua:1049` freeze hook | synth only | right |
| `lib/midi_in.lua:485-488` own setters | else grain_pitch | right; comment only (1e's file) |
| `lib/sequencer.lua:404-417` `note_param` and `value_note` | else grain_pitch, rate root 60 | right (1e's file in wave 1, 2b's in wave 2) |
| `lib/variation.lua:105` `scale_note` | synth, else root + 60 | right (1e's file) |
| `lib/variation.lua:243` layout sources | synth, buf 1, input | optional: add `SOURCE_VOICE_FIRST + 1` (1e's file) |
| `lib/expression.lua:90-96` `placement` | synth, buffer, else size | right |
| `lib/expression.lua:466-467` layout sources | three kinds | optional: a fourth |
| `lib/voice_mix.lua:162-163` layout sources | three kinds | optional (1a's file) |
| `lib/pages/main.lua:98-105` `main_param_entry` | else input | right: a voice source's main param is an input voice's (design, Calls) |
| `lib/pages/main.lua:114-120` `main_fields` | else input | right |
| `lib/pages/main.lua:152` source label | the option name | right through `voice_source_label` |
| `lib/pages/main.lua:324-325`, `339` layout states | buffer and input | add a voice-source state (`v2` drawn) (0d's file) |
| `lib/arc/main.lua:30` `not synth and not buffer` | input | right; replace with `voice_uses_input(i) or voice_uses_voice(i)` (the AGENTS rule) |
| `lib/ui/voice_rows.lua:27-33` `section_keys` | synth section nil for input | right: none for a voice source (0d's file) |
| `lib/pages/voice.lua:229` | buffer's undo section | right |
| `lib/pages/voice.lua:322-354` layout sources | synth, buf 1, input; no synth section for input | add a voice source, skipping its synth section as for the input (0d's file) |
| `lib/history.lua:24-27` `uses_input` | the input only | right (no history for a voice source); use `voice_uses_input` |
| `lib/history.lua:38` | input layout | right |
| `lib/mutation.lua:284` drift | buffer only | right |
| `lib/positions.lua:67`, `367`, `401`, `686`; `lib/loops.lua:47`; `lib/scan.lua:64`, `80`, `102`, `106`, `207`; `lib/slices.lua:401-408`, `441-444`, `503`; `lib/playheads.lua:40`, `74`, `218`; `lib/bookmarks.lua:18`; `lib/samples.lua:220`, `393-394`; `lib/buffers.lua:616`, `620`; `lib/ui/slice_editor.lua:214`, `442`, `463`; `lib/pages/buffer.lua:289`, `392`, `500`, `570-581`; `lib/arc/buffer.lua:64`; `lib/pages/seq.lua:388`, `425`, `982` | buffer only | right |
| `lib/positions.lua:94` | the same source again | right |
| `lib/scenes.lua:263`, `488` | source default, change | right |
| `lib/scenes.lua:1247` | `1..#SOURCE_OPTIONS` | right (17 automatically) |
| `lib/grid/core.lua:484-501` `valid_source`, `source_key`, `source_level` | options 1..#SOURCE_OPTIONS; `is_free(option - 1)` for every option | 17 automatically; `is_free(10..16)` reads `status` of no slot (unsure: `lib/buffers.lua:1199-1202`, a `status` of an invalid slot). 2c replaces it |
| `lib/grid/layout_128h.lua:134`, `311`; `layout_128v.lua:120`, `244`; `layout_256.lua:589` | `#SOURCE_OPTIONS` columns or rows (10) | 17 runs off a 16-column grid (128h `x <= 17`, 256 column 17) and over the freeze column (128h `LAYOUT_128H.freeze_column`, 256 column 12). 0e removes these pages (§0.5); if any survives to 1d, cap it |
| `lib/grid/layout_64.lua:173` | buffer level | right |
| `lib/engine_sync.lua:569-573` | `source - 1` | right |

### 3. Order and seams

- **Needs 0d** (format 10; `lib/pages/main.lua`, `lib/pages/voice.lua` and `lib/ui/voice_rows.lua` as 0d leaves them) and 0b's `fixedBufferBytes`.
  - 0b's out-ring term must be `numVoices × 2 × ringSeconds × sampleRate × 4`, a function of the sample rate as `highMemoryBytes(seconds, sampleRate)` is (`StrataPerformance.sc:248-252`). The design's "10.8 MB" is the 48 kHz figure, 10,752,000 bytes.
  - `test/engine_check/performance.scd:94-101` compares `highMemoryBytes` with what the rings area allocates. Add the out rings to that comparison.
- **Needs 1a's tap.** The writer records `areaState[\record][\voiceTaps][v]`, which 1a reworks ("the tap in StrataRecord.sc").
  - §5 says the ring holds "everything the voice sounds dry". With 1a's per-voice `v<i>_dry`, the tap could sit before or after the dry level.
  - If it sits after, a voice at dry 0 writes silence into its out ring, and its readers grain nothing. 1a must say where the tap is; 1d's user page follows.
- **Gives 2c** source values 11-17 (Lua) and 10-16 (engine), `voice_uses_voice`, `voice_source_voice`, the channel param and its handler.
- **Gives 3b** `input_channel` (out of presets) and the 17 sources.
- **Lines in files other wave-1 packages own** (1d lands last of the sound packages):
  - 1c's `lib/voices.lua` grain record: the local at 284 and the comment at 351-354 ("an input source's level and pan"). The globals at 229-248 are module-level (0d's file).
  - 1c's `lib/constants.lua`: its 65-74 and 316-318. 1c edits 55-58 and 314.
  - 1c's `test/norns_stubs.lua`: 1d edits 448-449, 582 and 673; 1c edits 293-294, 551-555 and 585.
  - Shared with 1c, 1b and 2a: `test/engine_check/structure.scd:80-87` and 495-505.
  - Shared with 1b (delay) and 1e (tuning): `test/engine_check.scd:24-25` (`areaOrder`) and `.github/workflows/test.yml:104-111`. Keep every name in order; give each new area its shard.
  - 1e's `lib/variation.lua`: line 243 (optional) and the comment at 97-101.
  - 1e's `lib/midi_in.lua`: the comment at 478-479 (optional).
  - 1e's `lib/sequencer.lua`: comments only (optional).
  - 1a's `lib/voice_mix.lua:162-163` (optional layout state).
  - 1c's grains and variation areas: none needed.
  - The memory area (0b's recast, 1f-1j's limit lines): 1d's cases.
- **AGENTS rules made false** (counts are words):
  - 17 (40): add `docs/notes/engine/outrings.md` (+1).
  - 123 (41): add `StrataOutRings.sc` (+1).
  - 160 (34): above (+6).
  - 202 (45): "**Buffer and input sources have no voice synth**" becomes "**Buffer, input and voice sources have no voice synth**" (+2).
  - 204 (30): "**Ring writers** run at the tail of `voiceGroup`, ..." becomes "**Ring writers** run at the tail of `voiceGroup` and the output rings' in the tap group (`softclip`), ..." (+9).
  - 206 (40): "only its writer writes a voice ring or the input ring" becomes "a voice ring, the input ring or an output ring" (+3); "an input freeze's copy" becomes "a copy freeze's (input or voice source)" (+3).
  - 207 (50): "an input freeze uses only the voice's copy ring" becomes "an input or voice-source freeze uses only ..." (+3).
  - 241 (13): "`voice_uses_synth(i)` / `voice_uses_buffer(i)`, never `not voice_uses_synth` (that includes input)" becomes "`voice_uses_synth`, `voice_uses_buffer`, `voice_uses_input`, `voice_uses_voice`, never `not voice_uses_synth` (that includes input and voice sources)" (+6).
  - 150 (55): `setGrainSource`'s neighbor row; add "handler-only `inputChannel` 0 stereo / 1 left / 2 right" (+7).
  - The architecture diagram (~41-46): "Voice source: Voice tap → Out Ring Writer (tap group) → Output Ring → strataGrainRing → Other Path" (about +12).
  - 213: the buffer memory list is 0b's to rewrite (it names the four sets).
  - The named-constants paragraph at 305: `SOURCE_VOICE_FIRST` only if a docs test reads it (none does now; 1390 checks quoted values).
  - Total about +55 words.

### 4. Tests

To re-base:
- `test/engine_check/lifecycle.scd:431-434` (10 becomes 17).
- `docs_test.lua:192`: keep, and add `assert_equal(spec.voice_source_first, local_value("SOURCE_VOICE_FIRST") - 1)`.
- `docs_test.lua:437` (the stub's `inputSource follows numBuffers`): add the same for `voiceSourceFirst`.
- `params_setup_test.lua`'s fixture list: 7 × `options` for `v<i>_source` (17 options) and 7 × `added v<i>_input_channel`.
- `voices_test.lua` (5 lines with `SOURCE_INPUT`): the new predicates.
- The page layout tests pick up new states automatically (`layout_states`).

New unit tests:
- `voices_test.lua`:
  - "voice_uses_input and voice_uses_voice: exactly one of the four predicates holds for each of the 17 sources".
  - "voice_source_voice: 11-17 give 1-7, others nil".
  - "voice_source_label gives v1..v7 for voice sources".
- `engine_sync_test.lua`: "source 11-17 send setGrainSource 10-16; the stub accepts 16 and rejects 17".
- `history_test.lua`:
  - "v<i>_input_channel: stereo/left/right, sent as inputChannel 0-2, a scene's discrete key, a VOICE row only on an input voice".
  - "a start sends inputChannel before voiceOn".
- `scenes_test.lua`: "a scene with source 17 is valid; 18 is set aside".
- `pages_main_test.lua`: "a voice on voice 2's ring shows v2 and its main param is grain size".
- `arc_pages_test.lua`: "MAIN ring 3 on a voice-source voice is grain pitch".
- `grid_layout_256_test.lua` or faders: "a voice-source voice's faders start with grain params then level and pan" (the `uses_ring` group).
- `freeze_test.lua`: "a voice-source voice freezes (hold; spectral offered on high), a switch unfreezes".
- `notes_test.lua`: "an extra note on a voice-source voice plays its rate as grain pitch (input kind)".

New engine check area `outrings` (file, `areaOrder`, shard and `docs/notes/engine/outrings.md`; the docs test at `docs_test.lua:1048` checks all three):
- "seven writers, `\strataOutRingWrite`, at the tail of the tap group after `\strataTapPreMaster`; effectKeys; ring frames = ringSeconds × sampleRate; bufnums unchanged across a voice's start, stop and switch".
- "the writer's law": 0.25 in gives 0.25; 2 gives 0.875 (softclip); NaN and inf give 0.
- "a reader hears the tap": voice 0 plays a timecode into its tap path, voice 1 on source 10. The read lag equals two blocks + `ringReadMargin` within a sample (the rings area's timecode method, `rings.scd`), sample by sample across a block.
- "a self-read plays" (source 10 + i on voice i).
- "a loop holds at full scale": voices 0 and 1 read each other at size 0.5, density 200, spread 0, level 2. After 5 s, every out-ring sample is at most 1 and finite, and the master's output is finite. No `replaceBadVoiceMix` fires.
- "a stopped, muted or gated read voice gives its readers silence; nothing is sent to them".
- "freezing the read voice leaves its readers' bufL/bufR unchanged".
- "hold on a reader copies the 4 s behind its read point of the read voice's ring into its copy ring":
  - The copy ring's samples equal the out ring's span.
  - The readers are faded first (`ringLevel 0`, `bufferFadeWait`).
  - A switch during the fade cancels it (`ringChanges`).
  - Unfreeze points back at the out ring in one bundle with `freeze 0`.
- "spectral on high: one copy writer of the read voice's tap in the tap group, freed at unfreeze and at a switch".
- "inputChannel":
  - 1 gives both bufL and bufR the input's left ring; 2 the right; 0 stereo.
  - On a frozen input voice, the copy's left twice.
  - The kept value survives a switch away and back.
  - It is no control of either grain def (`controlPairs` drops it).
  - A voice source ignores it.
- "setGrainSource 16 accepted, 17 and -1 ignored".
- "an extra note on a voice source is `\input` kind, its pitchShift per note".

Memory area: add V2 (every voice switched between three other voices' rings) and V4 (V2 with the pool full, sixteen ring notes live and cutting) from the prototype (`engine-grain.md` appendix), against 3072/3584 and 1280.
- On high these run seven spectral copy writers, which no existing case does with ring readers.
- R2 read V2 at 4118-4135 and V4 at 1882-1899 on high before 3.8's other additions.
- V1, V3 and V5 mirror existing cases within 2 KB and can be left out.

### 5. Risks and open points

1. **Is the tap before or after 1a's dry level** (Seams)? Unsure: 1a's facts are another gatherer's.
2. **The copy of a 4 s out ring into a 4 s copy ring.** `copyInputSpan` takes 4 s ending `ringReadMargin` before the head; the input ring is longer than the copy. For an out ring of the same length:
   - The copy's oldest `ringReadMargin` plus a block or two are the newest audio: a seam of about 8 ms at the copy's start.
   - It is low risk: the frozen read point stays `grainMaxSeconds` back and the scan wraps the seam anyway.
   - Otherwise copy `ringSeconds - (ringReadMargin + 2 blocks)` and leave the rest silent.
   - Not measured.
3. **`ringReaders` records the reading voice, not the ring** (facts §1.1). Nothing needs "the readers of ring j": a ring only appends, and no reader is told anything. Say so in rings.md rather than adding a map.
4. **The design is silent on whether a voice source takes the input channel.** §5 and §12 tie it to an input voice. Recommended: input only, as above.
5. **Loops** were reasoned, not run (facts' Unsure). The check's loop case is the first measurement. `replaceBadVoiceMix` could still trip on a NaN; `softclip` of NaN is NaN, which `zeroBadValues` zeroes before it.
6. **The 17 options fit the screens** on VOICE's `source` row ("voice 7", 7 characters, where "input" is 5) and BUFFER's field (`v2` through `voice_source_label`). The layout tests check both ends.
7. **The grid's source pages** (old layouts) must be gone before 1d (0e). If 0e keeps `grid_core.source_level`, its `is_free(option - 1)` for 10-16 is a status read of no slot (unsure what it returns: `lib/buffers.lua:1199`).
8. **Spectral copy writers.** Each reader on high runs its own, about 80 KB. Seven readers run seven, which the high pool cases must hold (V2 and V4 above).

---

## Package 2b: the arpeggiator

### 1. Files

- `lib/arp.lua` **(new)**, `S.lib.arp`.
  - Included after `lib/notes.lua` (strata.lua:88) and `lib/variation.lua` (66). Anywhere after both works: nothing reads `S.lib.arp` at include time. I propose right after `S.lib.notes`.
  - `test/unit/arp_test.lua` (new).
  - `docs/notes/lua/arp.md` (new, Must not break).
  - The module-table row in AGENTS (about 8 words).
- `lib/variation.lua`:
  - `interval_set` at 128-149 stays the set.
  - `send_intervals_now` at 152-158 sends `S.lib.arp.list(voice_idx, M.interval_set(voice_idx))` (the ordered list, at most 8) in place of the set.
  - `M.send_intervals` at 161-163.
  - The scale action's chord resend at 385-387.
  - The record's `sync` at 330-335 already calls `send_intervals_now`.
  - With tuning (1e), `interval_set`'s chord branch at 133-142 becomes degrees of `S.lib.tuning.allowed()`: 1e's edit, before 2b.
- `lib/notes.lua`. The seam is in `M.play` at 545-667:
  - After branch 1 (565-591, the same owner and key in a slot) and the slot-1-free test (596-597), before `if note.extra_only` (599).
  - The test: the voice's arpeggiator is on, the voice runs, its own note holds slot 1 unparked, and the note is not `own_only`. Then `return S.lib.arp.hold(voice, played)` in place of branches 3-6.
  - The step chord's notes 2..n are `extra_only` (`lib/sequencer.lua:537-538`), so the test must precede 599.
  - Releases reach the arpeggiator when `M.find` fails:
    - `M.release` (669-675)
    - `M.release_owner` (706-717)
    - `M.forget_owner` (723-737)
    - `M.forget` (739-751)
    - `M.release_all` (753-763)
    - the voice-stop hook (973-985)
  - New: `M.take_extras(voice)`, for the arpeggiator turned on. It returns each held extra note's `{owner, key, pitch}` and cuts its slot (`noteOff(v - 1, slot - 1, 1)`, `forget`).
- `lib/sequencer.lua`: `play_chord` at 717-726 calls `S.lib.notes.play` for notes 2..n; it works through the seam unchanged.
  - `end_chord` at 336-341 (`release_owner(voice, "seq")`) reaches the arpeggiator through `release_owner`.
  - `apply_step`'s per-note releases at 649-651.
  - "A step's chord does the same for its step" therefore needs no sequencer edit beyond tests, unless a ratchet must reshuffle (Risk 6).
- `strata.lua`: the include.
- Tests: `test/unit/arp_test.lua`, `notes_test.lua`, `sequencer_test.lua`, `variation_test.lua`, `midi_in_test.lua` (latch and release).
- Notes: `docs/notes/lua/notes.md` (Must not break, below), `docs/notes/lua/sequencer.md` and `docs/notes/lua/variation.md`.
- User pages: `docs/user/voices-and-grains.md` (an arpeggiator section), `docs/user/pages/voice.md` and `docs/user/midi.md:16`.
- No engine file: the counter and the fold are 1c's. If 1c's measure finds the fold over the limit, 1c drops `arpFold`. 2b then writes the there-and-back list itself, thinned to 5 notes (2c - 2 ≤ 8), and sends `arpFold` never (§1, "If a floor fails").

### 2. Names

- `M.ARP`:
  - `section = "grain"` (§12: the grain section).
  - `modes = {"off", "up", "down", "up-down", "shuffle"}`.
  - `mode_index = {off = 1, up = 2, down = 3, up_down = 4, shuffle = 5}`.
  - `shuffle_seconds = 4`.
  - `max_steps = 8` (`S.constants.NOTE_SLOTS`, equal to the engine's `interval1..8`).
- Param `v<i>_arp`: option `ARP.modes`, default 1.
  - A registered record `{name = "arp", count = 1}`.
  - `grain_keys.arp = {name = "arpOn", value = function(x) return x > 1 and 1 or 0 end, carry = false}`.
  - `sync(voice_idx)` sends `setGrainParam(v - 1, "arpFold", up_down and 1 or 0)`. One param needs two engine controls, so the fold goes through `sync` and the action, as variation's `intervals` action sends directly.
  - The action:
    - It sends `arpFold`.
    - Turned on with extra notes held, it takes them (`S.lib.notes.take_extras`).
    - Turned off, it forgets its chord.
    - Either way it resends the intervals (`S.lib.variation.send_intervals`).
  - `scene_defaults = {arp = 1}`, `discrete = {arp = {1, 5}}`.
  - `voice_rows = {section = "grain", rows = {"arp"}}`, after 1c's rows (registration order).
  - `fader = false`. No randomize.
  - Scene format 10 gains `arp`; presets take it "in".
- Functions:
  - `M.on(voice)` and `M.mode(voice)`.
  - `M.list(voice, set) -> {semitones ...}`. It holds at most 8 entries. The held chord's intervals come from the own note if a chord is held, else `set`. Up: ascending. Down: descending. Up-down: ascending; the engine folds. Shuffle: the current shuffle.
  - `M.hold(voice, played)` returns what `play` returns (Risk 1).
  - `M.release(voice, owner, key) -> bool`, `M.release_owner(voice, owner)` and `M.forget_owner(voice, owner)`.
  - `M.clear(voice)`: the voice's stop, or the arpeggiator turned off.
  - `M.held(voice)`.
- The shuffle is redrawn at each of the voice's hits and at least every `ARP.shuffle_seconds`.
  - `S.register_voice_hit{name = "arp", hit = fn}` only marks the voice ("a hook never sends", `lib/state.lua:740-745`).
  - `S.lib.lfos.on_step(fn)` (`lib/lfos.lua:420-424`) sends the due resends and checks the 4 s timer. It is registered once at a start step, as notes' flush is (`lib/notes.lua:962-964`).
  - A resend is 9 `setGrainParam` (8 intervals and the count) and is not deferrable. Count it with `S.lib.engine_sync.count_sends(9)`, or send only the changed entries.
- No `START_ORDER` or `CLEANUP_ORDER` entry unless the step hook needs one. The notes flush's hook is installed in its start step `notes_load`; the arpeggiator can hook from `S.register_start` at a new `START_ORDER.arp`, and needs `CLEANUP_ORDER` only if it keeps a clock (it should not).
- Intervals are in **semitones, fractional**, as the engine adds them (`StrataVariation.sc:45-50`, `midiratio`). A held pitch is a fractional note after 1e's `pitch_of_key`. Its interval is `pitch - own pitch`, where the own pitch is slot 1's (`lib/notes.lua` `M.own_pitch`, 375). In a tuning of any number of tones, a list of fractional semitones carries the cents exactly. Quantize on still snaps each step (1e's table).

### 3. Order and seams

- **Needs 1c** (`arpOn`, `arpFold`, the step on `interval1..intervalCount`) and **1e** (`lib/variation.lua`'s tuned chord set and the tuned key and step pitches).
- **The AGENTS rules it amends**:
  - Line 262 (88 words): "a chord's further notes are extra notes through `S.lib.notes`" becomes "... through `S.lib.notes`, or on an arpeggiating voice its list (`S.lib.arp`)" (+7).
  - Line 196 (55) and line 265 (33) stay true: an arpeggiated note creates no node and enters through `S.lib.notes.play`.
  - `docs/notes/lua/notes.md` Must not break needs:
    - "an arpeggiating voice's further notes are the arpeggiator's, never a slot";
    - "the note hooks hear every note once" (Risk 3);
    - "a running voice with no held note never keeps its own note parked" (the park, Risk 2).
  - `docs/notes/lua/sequencer.md`: a step's chord on an arpeggiating voice.
- **Gives 3b** the `arp` key.

### 4. Tests

- `arp_test.lua`:
  - "v<i>_arp's options and default; sends arpOn 0/1 and arpFold 1 only for up-down".
  - "no chord: the list is the interval set: up ascending, down descending, up-down ascending with fold, shuffle a permutation".
  - "a held MIDI chord C-E-G on a running voice: intervals 0, 4, 7 (own note C), intervalCount 3; no noteOn on slots 2-8; the pool unused".
  - "a key up in release mode removes its interval and resends; under latch the list stays until the next chord".
  - "a step's chord of three notes plays as the list for its step and ends with the step".
  - "turning it on while two extra notes sound: their pitches join the list, their slots get noteOff cut; turning it off: the list ends (intervalCount 0 for no set), the own note plays on, the other keys do nothing until played again".
  - "shuffle: a hit marks the voice, the next LFO step resends; 4 s without a hit resends".
  - "a 19-tone tuning (1e): intervals fractional".
  - "MPE notes on an arpeggiating voice: entries without per-note expression".
- `notes_test.lua`: "play on an arpeggiating voice returns <Risk 1's value> and takes no slot"; "release, release_owner, forget_owner and release_all reach the arpeggiator's entries".
- `variation_test.lua`: "send_intervals sends the arpeggiator's list when it is on".
- `sequencer_test.lua`: "a chord step on an arpeggiating voice sends no noteOn for notes 2..n".

### 5. Risks and open points

1. **What `S.lib.notes.play` returns for a note the arpeggiator takes** is open. Callers read it:
   - `lib/midi_in.lua:527-532`: `slot == 1` ends a step override; `if slot` keeps the expression.
   - `lib/sequencer.lua:698` compares `== 1`.
   - `lib/slices.lua:423`.
   - Proposed: a constant `S.lib.notes.ARPEGGIATED` (a string), never 1, truthy, so MIDI keeps its expression record and nothing else changes. `lib/expression.lua` then finds no slot for the key (`M.find`, 231 and 261) and drops its expression. Per-note MPE expression cannot reach one grain stream; the user page says so.
2. **The own note's park under an arpeggio.**
   - Today the own note parks when its key lifts with other notes held (`release_slot`, `lib/notes.lua:653-657`, `others_held` counts slots 2-8).
   - The arpeggiator's entries hold no slot, so the own note would not park and would keep sounding the arpeggio. That is what §4.3 wants ("the own note sounds as it does today"), but it means the arpeggio carries on after the own key lifts. Its intervals stay relative to the lifted note's pitch.
   - The design is silent on whether the list re-bases on the lowest held key. Recommended: keep the base until the list empties.
3. **The note hooks** (`lib/notes.lua:211-221`; `lib/io/targets.lua` plays external targets from them):
   - An arpeggiated note in no slot runs no `started` or `ended`, so crow, MIDI out and Just Friends targets hear only the own note.
   - The design is silent. Either the arpeggiator runs the hooks (a pseudo-slot number above `NOTE_SLOTS`, which `lib/io/targets.lua` must accept), or the user page says targets play the own note alone.
4. **Whether the own note (interval 0) is a step** of the held chord's list. "Up to eight held pitches, as intervals from the voice's own note" reads as including it, so a two-key chord alternates. Recommended: include it.
5. **`intervalProb` while the arpeggiator is on.** The prototype's `\min` stepped every grain, ignoring the chance. The design is silent. Recommended: the step replaces the draw entirely, and VOICE dims `interval prob` while the arpeggiator is on.
6. **The shuffle at each hit** is 9 messages a voice. At 1/16 steps at 120 BPM on seven voices that is about 500 a second, inside the 1500-a-second budget (`ENGINE_BUDGET`), but uncounted today. Count it.

---

## For the planner

1. **1c pushes voices to nine fader pages.** It swaps `grain_env` for shape and skew, one more fader. Resonator and every buffer voice go from 32 to 33 faders, so from 8 to 9 pages (scratch probe through the harness; `grid_layout_256_test.lua:15-24` pins 8). §10.4's faders page draws eight page keys.
2. **A rank-0 fader group in `lib/grain.lua` sits after the nine crossmod faders, not where `grain_env` was.** `fader_param_ids` sorts by rank, then registration order (`lib/grid/faders.lua:35-57`). The exact place needs the keys in the built-in grain group (`lib/voices.lua:437`).
3. **Keep `envBuf` as an engine-owned override, and send the bank's base as an engine-owned `windowBank` control.** Five checks in four areas set `envBuf` to a rectangle for timecode reads (grains 538, variation 90, freeze 113, rings 152 and 450). A baked-in bank bufnum breaks under the check's second engines, as `scaleBuffer` does (`docs/notes/engine/variation.md:7`).
4. **`grainRate` and `grainSignal` must build today's graph when the 3.8 keys are absent.** The check-only 3.2 and 3.3 copies call `e.grainRate` with no arpeggiator keys (`test/engine_check.scd:188`, `modulation.scd:114`), and `mix.scd:39` calls `engine.grainSignal` with its own Event.
5. **Use a `Stepper` for the arpeggiator, not `PulseCount`.** A float count stops at 2^24 grains (about 23 h at 200 a second).
6. **The master density cannot reach overlap mode without a Lua send or a new control.** The engine knows it only inside `grainDensity`. Option (a) edits `lib/engine_sync.lua:535-549`.
7. **"Overlap takes the density's row" needs `lib/ui/voice_rows.lua` (0d's file).** A registered record's `when` hides only its own rows. MAIN's field 3 and arc ring 4 stay on density: the design is silent.
8. **The test harness needs allowance lists the plan must create.** New params break the 3.7.0 params fixture: `PARAM_FIXTURE_ALLOWED` has no `added` kind (`params_setup_test.lua:996-1016`). The start fixtures (`engine_sync_test.lua:1653`, `system_37_test.lua:85`) take no allowance. 1c, 1d and 2b each move both.
9. **1d's engine work is small and its seams are wide.** One new area at order 135 writes the taps in the tap group (stop order is descending, so it frees before the group). The `copyInputToCopyRing` family is widened, not renamed, and `inputHeadFrame` takes a bus (it is in `AREA_CALL_METHODS`, `structure_test.lua:1446`). The stub's `setGrainSource` range (`norns_stubs.lua:673`) and `lifecycle.scd:431` move. The tap's place against 1a's dry level is open.
10. **2b's chord path has four silent points.** What `play` returns, the own note's park, the note hooks for io targets, and interval 0 as a step all touch `lib/notes.lua`'s "Must not break" list, and the plan must rule on each.

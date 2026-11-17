# 3.8 plan facts: package 1e, tuning

Read against `main` at 2edbfa96 (design `docs/design/3.8-design.md` §6, §12, §14; facts `docs/design/3.8-facts/lua-tuning.md`). I ran `lua test/run.lua` on `variation_test` (26/0), `pages_setup_test` (33/0), `files_test` (34/0) and `io_midi_out_test` (76/0), Lua probes of norns' `intonation.lua`, `musicutil.lua` and the stub's glyph widths, and one sclang 3.14.1 probe (no server) of the table construction below. Scratch: `/tmp/claude-1000/-home-sethbc-src-strata/7b6fc544-bdee-4477-ba59-2c1dad21aefd/scratchpad/plan-tuning/` (`table.scd`, `cents.lua`, `chord.lua`, `w2.lua`). No engine check was run; the building package must run `variation`, `notes`, `memory`, `effects` and the new `tuning` area on its own port.

## 0. The order a worker builds it in (each step ends in a commit)

1. **Engine: the table and the two commands** (`StrataScale.sc`, a new `tuning` area, the stub's argument checks, `PENDING_COMMANDS`, `AGENTS.md`'s rows). Lua sends nothing new yet.
2. **`lib/tuning.lua`, its two text params, the read hook's text default, the start send** (the commands leave `PENDING_COMMANDS`).
3. **The five sites** (`lib/variation.lua`: mask, snap, tone walk, filter, MIDI key, chord; `lib/sequencer.lua`'s degrees), `custom` and `scale_mask`, the dense-tuning turn rule.
4. **Built-in tunings, the `.scl` parser, the folder and `lib/files.lua`'s exported lister.**
5. **The editor** (`lib/ui/scale_editor.lua`), SETUP's row, its layout states.
6. **MIDI out's MPE bend** (`lib/io/midi_out.lua`, after the Wave 0 #772 fix lands) and the plain MIDI out and nb user pages.
7. **Docs pass**: notes files, user pages, `AGENTS.md` rules, the changelog fragment.

Steps 2 and 3 could merge; 3 needs 2's module, 4 needs 2's apply path, 5 needs 3 and 4.

---

## 1. Files

### Step 1, engine

- `lib/engine/StrataScale.sc` (140 lines; rewrite of 74-139). Sites today: `scaleBuffer` :77 (12 frames), `scaleRootAndMask` :80, `allocScaleBuffer` :83-91 (`Buffer.alloc(context.server, 12, 1, ...)` :89), `scaleOffsets` :100-106, `validScaleRoot` :108, `validScaleMask` :110, `setScale` :114-122, `addScaleCommands` :124-128, `quantizedOffset` :135-139. The file header :1-5 and the area comment :11-12 name the 12-frame buffer.
- `lib/engine/StrataVariation.sc`: **no edit needed** if `quantizedOffset(pitchShift, offset, scaleNote)` keeps its signature (its one caller is `grainRate`, :47-48). Only its comment :30-32 mentions the scale; leave it. This keeps 1e out of 1c's file.
- `test/engine_check/tuning.scd` **(new)**; `test/engine_check.scd:24-25` (`areaOrder` gains `\tuning`, after `\variation`); `.github/workflows/test.yml:104-111` (a shard gains `tuning`: `mix,variation,tuning,grains,structure,performance` is the natural one); `docs/notes/engine/tuning.md` **(new, opens `## Must not break`**; `docs_test.lua:1023` and `:1048` require it).
- `test/engine_check/variation.scd`: the scale-buffer checks :100-124 pin the 12-frame buffer and its offsets (`engine.scaleBuffer.numFrames == 12`, `bufferOffsets.value == Array.fill(12, 0)`, the C and D major offset arrays, the bad-root case). They move to `tuning.scd`, rewritten for the table. `majorOffsets` (:111) must stay defined: the grain checks at :162, :266 and :274 read it. The grain-level quantize checks :155-169 (C major from C4, jitter 12) and :240-281 (buffer voice at bufRate 2^(4/12), the half-semitone bend) only test "lands on a C major tone" and pass unchanged under the new table (reasoned, not run). **1c owns this area** (§14): see section 3.
- `test/engine_check/notes.scd`: nothing pins the table (its scale lines, :81-88, :413-444, :520-567, are `scaleNote`, `rootNote` and `noteScaleNote`, untouched). Must still pass unchanged.
- `test/engine_check/effects.scd:379-391` reads `fresh.scaleRootAndMask` and expects `[0, 4095]`: keep the method and that start state.
- `test/engine_check.scd:94` comment (3.2's copies bake in `scaleBuffer`'s bufnum): still true; no edit.
- `docs/notes/engine/variation.md`: its "The scale area" section (`grep -n "^## " ` puts it at :30-45) and its Checks list move to `tuning.md` or point there.
- `test/norns_stubs.lua:664-760` (the per-command `checks` table; `:3112` asserts "the engine stub has no argument check for engine.<name>"): two entries. 0c owns the file; these are registration-like lines.
- `test/sync_check.lua:216-217`: `PENDING_COMMANDS` gains `"setTuning", "setTuningTone"` in step 1, loses them in step 2.
- `test/unit/structure_test.lua`: a new test applying `per_sample_loops` (:1420-1428) to the table builder's body (`sc_method_body`, :1410-1418), as `:2175-2197` does for `StrataFiles.sc`.
- `test/unit/docs_test.lua:487-528` (#460, "the scale and bypass params' defaults equal the engine's start state"): parses `allocScaleBuffer`'s `state[\root] = 0;` and `state[\mask] = this.chromaticMask;`. Keep those two lines verbatim; extend the test (or add one beside it) to the tuning's start state (`state[\period]`, `state[\tones]`) against `TUNING.default`.
- `AGENTS.md`: see "AGENTS.md lines" below.

### Step 2, the module

- `lib/tuning.lua` **(new)**, `S.lib.tuning`.
- `strata.lua`: one include, `S.lib.tuning = include("lib/tuning")(S)`, between `lib/loops` (:65) and `lib/variation` (:66). Nothing in it is read at include time but `S.constants`.
- `lib/params_setup.lua`: `pset.default` :194-205 returns nil for a text param (comment :190-193 says so); 1e adds a text default. The two text params are added from the `scale` record (`register_params("scale", ...)` :729, before `voices` :731), so they join `pset.record_params` (:159-171) and the read hook walks them. 0d owns the file; 1a, 1c and 1d edit it in wave 1 too.
- `lib/constants.lua:166-205` (`START_ORDER`): one entry. `docs/notes/lua/state-and-voices.md` start table (`docs_test.lua:1369` requires a row per order; rows like :83). `test/unit/structure_test.lua:995-1053` (`start_steps()`, the expected effects of every step in order) gains the step.
- `test/unit/tuning_test.lua` **(new)**; `docs/notes/lua/tuning.md` **(new)**.

### Step 3, the sites

- `lib/variation.lua` (401 lines): header :1-12; `scale_options` :41-45; `current_scale` :48-52; `root` :55-57; `scale_mask` :62-69; `is_tone` :72-74; `snap_note` :78-86; `interval_set` :128-149 (chord :133-142); `send_scale` :166-168; `tone_freq` :172-185 (its whole-note walks :176-183); `freq_filter` :204-222 (the shadow :209-214); `snap_freq` :227-231; `midi_note` :234-237; `snap_quantized_freqs` :368-375 (local; must be exported); `add_scale_params` :379-396; scene fields :398-399.
- `lib/sequencer.lua`: `SEQ` constants :67-69 (`semitones`, `chromatic_mask`, `tone_tolerance`); `degree_semitones` :423-446 (the chromatic shortcut :431, the walk :432-445, the loop bound and its comment :436-437). `step_chord` :497-513 and `step_pitches` are log math and stay.
- `lib/midi_in.lua`: **no code change is needed**: the key becomes the pitch inside `S.lib.variation.midi_note` (called at :522), which every MIDI and MPE note passes; slices (:518-520) take a slice number, not a pitch. A comment at :509-511 ("snapped to the scale") and the notes (`docs/notes/lua/midi.md:15`, "exact equal-tempered pitch") change. §14 lists the file as 1e's; the worker may leave it untouched.
- Tests: `test/unit/variation_test.lua`, `test/unit/sequencer_test.lua`, `test/unit/midi_in_test.lua` (new cases), `test/unit/params_setup_test.lua` (fixture entries).

### Step 4, files

- `lib/files.lua` (156 lines): `list_folder` :54-64 and `sound_files` :68-79 are local. Export one generalized lister (names below).
- `lib/tuning.lua` (the built-ins and the parser), `test/unit/tuning_test.lua`, `test/unit/files_test.lua` (one test for the export).
- Folder: `_path.data .. "strata/tunings/"` (Strata's data is `_path.data .. "strata/"`, `lib/side_files.lua:24`).

### Step 5, the editor

- `lib/ui/scale_editor.lua` **(new)**, `S.lib.ui_scale_editor`; include in `strata.lua` after `lib/ui/slice_editor` (:122), since like `lib/ui/zones.lua:19` it may read `S.lib.ui_field_list` at include time.
- `lib/pages/setup.lua`: `SETUP_FIELDS` :63-80 (one row); the page record's `layout_states` :398-471 (the zones editor's states are built there by `zones_editor_state`, :368-389; the scale editor's go beside them); the header comment :1-13.
- `test/unit/ui_scale_editor_test.lua` **(new)**; `test/unit/pages_setup_test.lua` (re-based, below); `docs/notes/lua/ui/scale-editor.md` **(new)** or a section of `docs/notes/lua/ui-core.md` (the zones editor's notes are there); `docs/user/pages/setup.md` (:11, :29, :35 describe the zones editor's row and K3).

### Step 6, outputs

- `lib/io/midi_out.lua` (955 lines): `encoded` :147-158 (bend :148-153), `start_note` :285-352 (note :293; the MPE first values :318-332; shared-channel bookkeeping :337-346), `express_step` :361-394 (:379). Three `encoded(` call sites: :326, :342, :379.
- `test/unit/io_midi_out_test.lua` (the bend and MPE tests the facts name at :287 and :594).
- `docs/user/io/midi-out.md:21` (plain: "its nearest MIDI note") and :23-27 (MPE); `docs/user/io/nb.md:17` ("rounded to whole notes"). `lib/io/nb.lua:202` is unchanged (`math.floor(pitch + 0.5)`).

### Step 7, docs

- `docs/notes/lua/variation.md` (Must not break :3-8 and the body :10-28: "the nearest whole note", "musicutil.generate_scale", "the engine's rule for whole notes", the 0.8-semitone detent rule), `docs/notes/lua/sequencer.md` (degrees), `docs/notes/lua/midi.md:15`, `docs/notes/lua/io/midi-out.md` (bend), `docs/notes/lua/params.md` (the read hook's text default, if the hook is documented there).
- User pages: `docs/user/params.md:143-144` (Scale: add scale mask, tuning), `docs/user/midi.md:16` ("exact equal temperament"), `docs/user/sequencer.md:26` ("tones of the global scale"), `docs/user/voices-and-grains.md` (#scales), `docs/user/pages/setup.md`, `docs/user/files.md` if it lists data folders.
- `changes/<branch>.md` fragment; `docs/status.md` at the landing.

### AGENTS.md lines (7,744 words today; 0a frees room first)

- **:167**, the `setScale` row (37 words): add "applied in a tuning of twelve tones to an octave; any other tuning ignores the mask" (about +14).
- **Two new rows** (text below, about 70 words). Place them before the bold paragraph at **:183** (45 words), which says "the last fourteen rows" and names their notes files: appending after `setSlotGain` (:181) makes that paragraph false. Either insert the rows above :167's neighborhood or rewrite :183's count (every 3.8 command package has the same problem; one rule for all of them is the planner's).
- **Module table**: two rows (about 16 words), `lib/tuning.lua` before the `lib/variation.lua` row (:81, include order) and `lib/ui/scale_editor.lua` after `lib/ui/slice_editor.lua` (:116).
- **:16**, the engine notes list (30 words): add `docs/notes/engine/tuning.md` (`docs_test.lua:1036` requires every engine notes file be named).
- **:210**, "No per-sample sclang loop in engine code ... (a structure test enforces it in `StrataFiles.sc`)": add "and the tuning table" (+4).
- **:253**, "Scale quantize" (40 words): add the tuning, or a new bullet beside it, about 40 words: "**Tuning**: one tuning, `S.lib.tuning`'s; every MIDI key, snap, degree and chord goes through it (`pitch_of_key`, `snap`, `step`, `allowed`); only it sends `setTuning`/`setTuningTone`; the mask applies only to twelve tones of an octave. `docs/notes/lua/tuning.md`".
- **:233** ("`scaleBuffer`'s bufnum never changes") stays true if the method keeps its name (recommended).
- Total about +150 words.

## 2. Names

### Engine (StrataScale.sc)

Constants (methods, the engine's habit, as `chromaticMask` :9):

| Method | Value | Lua mirror |
|---|---|---|
| `tuningMaxTones` | 128 | `TUNING.max_tones` |
| `tuningMinPeriod`, `tuningMaxPeriod` | 100, 4800 (cents) | `TUNING.min_period`, `max_period` |
| `octaveCents` | 1200 | `TUNING.octave` |
| `tuningOctaveTolerance` | 0.001 cents (an "octave" period test) | `TUNING.octave_tolerance` |
| `tuningRootKey` | 60 (degree 0's key is 60 + root) | `TUNING.root_key` (= `VARIATION.reference_octave`, 60) |
| `tuningTableFrames` | 2048 per the design (see section 5, point 2: 3072 or 4096) | `TUNING.table_frames` |
| `tuningTableLow` | -45 (design) | `TUNING.table_low` |
| `tuningTableResolution` | 10 frames a semitone | `TUNING.table_resolution` |

State, `areaState[\scale]`: keeps `\notes`, `\root`, `\mask`, `\buffer`; drops `\offsets`; adds `\tones` (Array of cents, first 0, ascending), `\period` (cents), `\pending` (nil, or `(count:, period:, tones: Array.newClear(count), received: 0)`).

Methods:
- `scaleBuffer` (keep the name: :77; `AGENTS.md:233` and `variation.scd` use it): now `tuningTableFrames` frames, each the pitch (a fractional MIDI note) of the nearest allowed tone to the frame's center `tuningTableLow + frame / tuningTableResolution`, a tie going down. Bufnum constant (allocated once in `allocState`, before every `addDefs`).
- `scaleRootAndMask` unchanged (`effects.scd:391`).
- `tuningTonesAndPeriod` (new, for the checks): `[tones, period]`.
- `tuningAllowed(tones, period, mask)` → Array of cents: the tones whose degree's bit is set when `tones.size == 12` and `(period - octaveCents).abs < tuningOctaveTolerance`, else every tone.
- `tuningTable(tones, period, root, mask)` → a Signal of `tuningTableFrames` (construction below). Pure: no state, no server.
- `sendTuningTable` → one `/b_setn` of every frame (below).
- `allocScaleBuffer` (:83-91): sets `\notes`, `\root` 0, `\mask` `this.chromaticMask` (keep these two lines verbatim for the #460 docs test), `\tones` `(0..11) * 100`, `\period` 1200, then `Buffer.alloc(context.server, this.tuningTableFrames, 1, { arg buffer; this.tuningTableMsg(buffer.bufnum) })`, the completion message being the whole table.
- `scaleOffsets` (:100-106): **removed**.
- `setScale(root, mask)` (:114-122): validation unchanged (`validScaleRoot` :108, `validScaleMask` :110); stores root and mask, rebuilds and sends the table.
- `setTuning(count, period)` (new): count an Integer 1..`tuningMaxTones`, period a finite Float in `tuningMinPeriod..tuningMaxPeriod`; else one console line and nothing (any earlier pending set is dropped either way? say: a bad `setTuning` leaves the pending set as it was). Starts `\pending`.
- `setTuningTone(index, cents)` (new): with no pending set, index outside 0..count - 1, or cents non-finite or outside `[0, period)`: one line, ignored. Stores it; when every index has arrived (`received == count`), validates (`tones[0] == 0`, strictly ascending), and on success commits `\tones` and `\period`, clears `\pending`, rebuilds and sends; on failure one line, the old tuning stays.
- `quantizedOffset(pitchShift, offset, scaleNote)` (:135-139), same signature:

```
quantizedOffset { arg pitchShift, offset, scaleNote;
    var base = scaleNote + pitchShift.max(0.001).ratiomidi;
    var frame = ((base + offset) * this.tuningTableResolution) - (this.tuningTableLow * this.tuningTableResolution);
    ^Index.ar(this.scaleBuffer.bufnum, frame.round) - base
}
```
  Today's is 9 UGen operations (max, ratiomidi, +, +, round, %, Index, +, -); this is 8 (the `* res - k` folds to one MulAdd). `Index` truncates and clips its index (the facts, `OscUGens.cpp:649-658`), so `round` first.

Commands (`addScaleCommands`, :124-128), and the `AGENTS.md` rows in the table's style:

```
| `engine.setTuning(count, period)` | `"if"` | Begin the tuning the grains quantize to: count 1-128 tones a period of period 100-4800 cents (1200 = an octave). Its tones follow as `setTuningTone`; the table is rebuilt when the last arrives. Other values are ignored |
| `engine.setTuningTone(index, cents)` | `"if"` | Tone index 0 to count - 1 of the tuning `setTuning` began, in cents above tone 0: tone 0 is 0, each above the last, all below the period. A set that breaks this keeps the old tuning |
```

### The table's construction (measured)

All per-frame work is Signal primitives (`_Add`, `_Sub`, `_Mul`, `_FDiv`, `_Mod`, `_Sign`, `_Max`, `_SignalFill`, `putEach`, `at` with an index Array, `SCClassLibrary/Common/Math/Signal.sc:49, 226-288`); the only sclang loop is over the boundaries between neighboring allowed tones (at most 129), each step one primitive pass over every frame:

```
// tones: cents, first 0; period cents; root 0-11; mask 1-4095
allowed = this.tuningAllowed(tones, period, mask);
ext = [allowed.last - period] ++ allowed ++ [allowed.first + period];   // one tone either side of a period
keys = (0 .. (frames - 1));                                               // the series primitive
f = Signal.newClear(frames).putEach(keys, keys);                          // frame numbers as floats
r = (f * (100 / res)) + ((low - rootNote) * 100);                         // cents from degree 0's key (rootNote = 60 + root)
k = (((rootNote - low) * 100) / period).ceil + 1;                         // whole periods that make r positive
s = r + (k * period);
x = s.mod(period);                                                        // cents into the period
base = s - x - (k * period);                                              // the period's start, cents
ek = Signal.newClear(frames).fill(ext[0]);
// for each boundary j (a while loop, not a function per frame):
//   ek = ek + ((x - midpoint_j).sign.max(0) * gap_j)      // x above the midpoint: the upper tone; a tie: the lower
table = ((base + ek) / 100) + rootNote;                                   // a Signal of pitches
```

Probe results (sclang 3.14.1 on this desktop, `table.scd`): 12-equal chromatic and C major and D major equal the brute-force "nearest allowed tone, tie down" at all 2048 frames; 19-equal equals the nearest 19-EDO tone at every frame but exact midpoints; the 12-equal values are exact integers; a non-octave period (13 tones of 1901.955 cents) is right but float32 leaves steps of 7.6e-6 semitones where two frames share a tone (frames 1051, 1241). Cost: 0.06 ms (12 equal), 0.18 ms (Partch 43), 0.55 ms (128 tones in a 100-cent period), allocating a handful of Signals, never a function per frame. The building package measures on 3.13 and states the CM3 estimate.

**Sending it.** `Buffer:setn`/`setnMsg` go through `setnMsgArgs`, which `List.addAll`s every value in sclang (`SCClassLibrary/Common/Control/Buffer.sc:421-437`): a function call per frame. Build the message as an Array instead: `[\b_setn, bufnum, 0, frames] ++ table.at(keys)` (`at` with an index Array returns an Array of Floats, measured: class Array, 1024 of 1024), sent with `context.server.listSendMsg(msg)`. One message of 2048 floats is about 10.3 KB; sclang's packets go to 65504 bytes (`common/scsynthsend.h:151`, `big_scpacket`) and scsynth's UDP receive buffer is 65536 (`server/scsynth/SC_ComPort.cpp:148`). `streamCollection`'s comment "1626 max size for setn under udp" (`Buffer.sc:272-273`) is the class library's own conservative chunk; one message keeps the table change atomic (no grain reads half a table). Measure on 3.13.

A structure test can run `per_sample_loops` on `tuningTable`'s body if the boundary loop is a `while` and the mask filter is in `tuningAllowed` (whose 12-tone `select` with `{ arg` would be flagged; it is per tone, not per frame: exempt it by name or write it with `while`).

### Lua: `lib/tuning.lua` (S.lib.tuning)

`M.TUNING` (local alias `TUNING`): `max_tones = 128`, `min_period = 100`, `max_period = 4800`, `octave = 1200`, `octave_tolerance = 0.001`, `root_key = 60`, `table_frames`, `table_low`, `table_resolution` (mirrors, for the docs test), `tone_tolerance = 0.01` (semitones; `SEQ.tone_tolerance`'s rule), `twelve = 12`, `default = {name = "12 equal", period = 1200, tones = {0, 100, ..., 1100}}`, `default_text = "1200 0 100 200 300 400 500 600 700 800 900 1000 1100"`, `folder = "strata/tunings/"` (under `_path.data`), `extension = "scl"`, `max_file_bytes` (proposed 65536), `name_max` (proposed 24 characters), `cents_format = "%.4f"` (trailing zeros dropped), `built_in = {...}` (section 2, built-ins).

Functions (proposed exact names):
- `M.name()`, `M.count()`, `M.period()` (cents), `M.tones()` (a copy, cents, first 0).
- `M.scale_active()` → true when `count == 12` and `|period - 1200| < octave_tolerance`.
- `M.allowed()` → cents above degree 0, ascending: the tones whose bit of `S.lib.variation.scale_mask()` is set when `scale_active()`, else every tone. Never empty (the mask is 1-4095).
- `M.pitch_of_key(key)` → fractional MIDI note: `root_key + root`, then `d = key - that`, `w = floor(d / count)`, `degree = d - w * count`, pitch `= that + (w * period + tones[degree + 1]) / 100`. For twelve equal it is `key` exactly, whatever the root (integer cents over 100).
- `M.snap(pitch)` → the allowed tone nearest `pitch`, a tie going down (today's `snap_note` rule, `lib/variation.lua:76-86`): position in periods from degree 0's key, the nearest of the period's allowed tones and the neighbors one period either side.
- `M.step(pitch, k)` → the k-th allowed tone strictly above `pitch + tone_tolerance` (k > 0) or strictly below `pitch - tone_tolerance` (k < 0); `pitch` itself for 0. This equals today's walk for whole-note tones (`floor(p + tol) + 1 ...` is the first whole note `> p + tol`, `lib/sequencer.lua:434-439`). Index arithmetic over the allowed list and periods: no loop bound.
- `M.equal_step()` → the step in semitones when `allowed()` is every tone of an equal division (all gaps equal within `octave_tolerance`), else nil (twelve equal with the scale off: 1).
- `M.text_of(period, tones)`, `M.parse_text(text)` → `period, tones` or `nil, reason` (tokens split on spaces; each matching `^%-?%d+%.?%d*$`, finite; first tone 0; strictly ascending; below the period; count 1-128; period 100-4800).
- `M.apply_text(text)`: the `tuning_tones` action's body: parse; on success store, `M.send()`, then `S.lib.variation.tuning_changed()`, `request_redraw()` (text params get no redraw from `redraw_on_param_changes`, `lib/params_setup.lua:744-756`); on failure one printed line and the param set back silently to the tuning in force.
- `M.send()`: `engine.setTuning(count, period)`, then `engine.setTuningTone(i - 1, tones[i])` for each tone (direct, not `deferrable`; up to 129 messages).
- `M.select(entry)` (a built-in or a parsed file): `params:set("tuning_name", name)`, then `params:set("tuning_tones", text)` (the second applies).
- `M.built_ins()`, `M.files()` (names in the folder, through `S.lib.files.files_of`), `M.parse_scl(text)` → `period, tones` or `nil, reason`, `M.load_file(name)` → entry or `nil, reason`.
- `M.add_params()`: `params:add{type = "text", id = "tuning_name", name = "tuning", text = TUNING.default.name}` (shown) and `params:add{type = "text", id = "tuning_tones", name = "tuning tones", text = TUNING.default_text, action = M.apply_text}`, `params:hide("tuning_tones")`; and `S.lib.params_setup.set_text_default(id, text)` for both (below). Called from `S.lib.variation.add_scale_params()` after `root` and `scale_mask`, so all five sit in the `scale` record before every voice.
- Start step: `S.register_start(START_ORDER.tuning, function() M.send() end)`, proposed `tuning = 55` ("lib/tuning.lua: the tuning to the engine (3.8)"): any free number before `startup_clock = 120` works; 55 keeps 112-119 free for 3b's `voices.data` load and 4d's first run. structure_test's `start_steps()` gains `{ "tuning", { "engine.setTuning", "engine.setTuningTone" x 12 } }` (check how the log records engine calls: `notes_load`'s entry lists `"engine.setNotePool"`, `structure_test.lua:1043`).
- No registry, no cleanup step, no global function. Names tests reach: `local_value("TUNING")` if aliased in `S.constants`; otherwise through `S.lib.tuning.TUNING`.

`lib/params_setup.lua` (proposed): `pset.text_defaults = {}`; `function M.set_text_default(id, text)`; `pset.default(param)` (:194) returns `pset.text_defaults[param.id]` for a `params.tTEXT` param that has one, nil for the others as today (the keyed options' hidden `<id>_key` texts, `lib/io/keyed.lua:65`, keep "none").

`lib/variation.lua` (names kept, meaning widened):
- `M.scale_options()` → `off`, the 41 musicutil names, `custom` (index 43, `#musicutil.SCALES + 2`). `M.VARIATION.custom_scale = "custom"`.
- `current_scale()` (:48-52) returns `musicutil.SCALES[index - 1]`, which is **nil for `custom`**: `scale_mask()` would read custom as off. `M.scale_mask()` (:62) gains `if index == custom then return params:get("scale_mask") end`; the chord path too.
- New param `scale_mask`: `{type = "number", id = "scale_mask", name = "scale mask", min = 1, max = 4095, default = 4095, action = ...}` (re-send, re-snap and chords only while `scale` is custom). A number param in a `register_params` record steps whole and is rounded by the read hook (`lib/params_setup.lua:159-171`). Scene field: `S.register_scene_field({id = "scale_mask", default = 4095, discrete = true})` beside :398-399.
- `M.snap_note(note)` (:78) keeps its name (mutation_test.lua:471 calls it) and returns `S.lib.tuning.snap(note)`. `is_tone` (:72) goes.
- `tone_freq` (:172): `S.lib.tuning.snap`, then `S.lib.tuning.step(tone, -1)` / `step(tone, 1)` to come inside the range.
- `M.midi_note(voice_idx, key)` (:234): `local pitch = S.lib.tuning.pitch_of_key(key)`; quantized: `S.lib.tuning.snap(pitch)`.
- `M.interval_set` chord (:133-142): see section 5, point 4.
- `M.snap_quantized_freqs` (export of the local :368) and `M.tuning_changed()` (re-snap every quantized voice, resend every chord voice's intervals).
- `freq_filter` (:204): the turn rule (section 5, point 9).

`lib/sequencer.lua`: `M.degree_semitones(voice_idx, k)` (:428) keeps its name and validity checks (:429); `if k == 0 then return 0 end`; `local step = S.lib.tuning.equal_step(); if step then return k * step end`; else `S.lib.tuning.step(pitch, k) - pitch`. `SEQ.chromatic_mask` and `SEQ.semitones` lose this reader (`semitones` stays for `value_note`, :416-417, and `step_chord`, :506).

`lib/files.lua` (proposed): `M.list_folder(folder)` (the local :54, exported unchanged) and `M.files_of(folder, extensions)` (the local `sound_files` :68 generalized: names, no folders, no dot files, extension lower-cased in the set), `sound_files(folder)` becoming `M.files_of(folder, SOUND_EXTENSIONS)`.

`lib/ui/scale_editor.lua` (S.lib.ui_scale_editor): `M.open()`, `M.close()`, `M.is_open()`, `M.note(key)` (the tap), `M.SCALE_EDITOR` (layout as `ZONES_EDITOR`, `lib/ui/zones.lua:29-34`: `visible = 6, first_y = 18, spacing = 7, value_right = 124`, the notes row's `class_x = 28, class_spacing = 8`, levels). An invariant ("scale editor": open ⇔ its owner is the modal top, but under SEQ's step editor as zones allows, `lib/ui/zones.lua:303-306`; the tap is its own while open).

`lib/pages/setup.lua`: `{label = "scale & tuning", kind = "action", hint = "open", run = function() S.lib.ui_scale_editor.open() end}`.

`lib/io/midi_out.lua`: `encoded(field, raw, detune)` (detune semitones, added to the bend's `12 * log2(bend)` before the range); `start_note` stores `record.detune = pitch - note` (note the clamped `round(pitch)`, :293; at the clamp edges detune can exceed 0.5, which the bend range still carries); the three callers pass the record's detune (:326 the new record's, :342 `other.detune`, :379 `record.detune`). Plain mode unchanged.

### Built-in tunings (cents, computed with `cents.lua`; ratios from `~/src/norns/lua/lib/intonation.lua`)

All have a 1200-cent period. Hold them as ratios (or generators) in the module and format through `text_of`, so a session and its reloaded PSET apply the same text.

| Name (proposed) | Source | Cents |
|---|---|---|
| `12 equal` | | 0, 100, ..., 1100 |
| `ji normal` | `JI.normal()` | 0, 111.7313, 203.9100, 315.6413, 386.3137, 498.0450, 590.2237, 701.9550, 813.6863, 884.3587, 996.0900, 1088.2687 |
| `ptolemy` | `JI.ptolemy()` | as normal but the tenth, 1017.5963 (9/5) |
| `overtone` | `JI.overtone()` | 0, 104.9554, 203.9100, 297.5130, 386.3137, 470.7809, 551.3179, 701.9550, 840.5277, 905.8650, 968.8259, 1088.2687 |
| `undertone` | `JI.undertone()` | 0, 111.7313, 231.1741, 294.1350, 359.4723, 498.0450, 648.6821, 729.2191, 813.6863, 902.4870, 996.0900, 1095.0446 |
| `lamonte` | `JI.lamonte()` | 0, 176.6459, 203.9100, 239.6068, 443.5168, 470.7809, 674.6909, 701.9550, 737.6518, 941.5618, 968.8259, 1172.7359 |
| `pythagorean` | fifths Eb to G#: 1/1, 2187/2048, 9/8, 32/27, 81/64, 4/3, 729/512, 3/2, 6561/4096, 27/16, 16/9, 243/128 | 0, 113.6850, 203.9100, 294.1350, 407.8200, 498.0450, 611.7300, 701.9550, 815.6400, 905.8650, 996.0900, 1109.7750 |
| `meantone 1/4` | quarter-comma, fifth 5^(1/4) = 696.5784 cents, fifths Eb to G# | 0, 76.0490, 193.1569, 310.2647, 386.3137, 503.4216, 579.4706, 696.5784, 772.6274, 889.7353, 1006.8431, 1082.8921 |
| `19 equal`, `24 equal`, `31 equal` | | 1200 i / n |
| `partch 43` | `JI.partch()` (43 ratios, 1/1 first, 160/81 last) | 0, 21.5063, 53.2729, 84.4672, 111.7313, 150.6371, 165.0042, 182.4037, 203.9100, 231.1741, 266.8709, 294.1350, 315.6413, 347.4079, 386.3137, 417.5080, 435.0841, 470.7809, 498.0450, 519.5513, 551.3179, 582.5122, 617.4878, 648.6821, 680.4487, 701.9550, 729.2191, 764.9159, 782.4920, 813.6863, 852.5921, 884.3587, 905.8650, 933.1291, 968.8259, 996.0900, 1017.5963, 1034.9958, 1049.3629, 1088.2687, 1115.5328, 1146.7271, 1178.4937 |

The Pythagorean and meantone spellings (which wolf, Eb to G#) are this file's call; the alternative flats (256/243 for Db, 128/81 for Ab) are another table. The stub has no `intonation` (facts §4): do not `require` it. Text sizes: Partch's text is 383 bytes; the worst 128-tone text at four decimals is 1,258 bytes (not "a 1 KB line", design §1).

### The `.scl` parser (rules from memory: check each against Scala's `scl_format.html`)

Believed Scala rules (unverified, from memory): a line beginning `!` is a comment, anywhere; the first other line is a description, which may be empty; the next is the number of pitches; then that many pitch lines, each a value then anything (ignored) after whitespace; a value holding `.` is cents (may be negative), otherwise a ratio `a/b` of positive integers or a whole number `a` (= a/1); 1/1 is implied and not listed; the last pitch is the period (the "formal octave"); pitches need not ascend; a reader may refuse a file over a size it chooses; leading whitespace is allowed.

What Strata's parser accepts (proposed, exact):
- At most `max_file_bytes`; read with `io.open(path, "rb")`, never `load`/`dofile`. `\r\n` and `\n` both end a line.
- Comments: lines whose first character is `!` are skipped. The first non-comment line is the description (kept only for the console; the tuning's name is the file's name without `.scl`, cut to `name_max`, control characters dropped, so a PSET line stays one line).
- Count: the next non-comment line's first token, a whole number 1..128 (`max_tones`); else "count is not 1-128".
- Pitches: the next `count` non-comment lines (blank lines skipped: unsure what Scala does), first whitespace-delimited token: cents if it matches `^[+-]?%d*%.%d*$` with a digit; a ratio if `^%d+/%d+$` or `^%d+$` with both terms positive; else "line N: not a pitch". `tonumber` alone would also read `0x10`, `1e3` and `inf`; the patterns exclude them. Cents of a ratio `1200 * log(a / b) / log(2)`.
- Fewer pitch lines than the count: "only N pitches". Lines after them: ignored.
- The tones are 0 then pitches 1..count-1; the period is the last pitch. Refused: a period outside 100-4800 cents (the engine's range; the design names only "0 or less"), a tone not strictly above the one before (a non-ascending file, a repeated 1/1 or 0.0), a tone at or above the period.
- Each refusal prints one line `tuning: <file>: <reason>` and returns `nil, reason` (the editor flashes the reason).

## 3. Order and seams

**Needs from earlier packages.**
- 0d: `lib/params_setup.lua` as 0d leaves it; and **an "added" kind in `PARAM_FIXTURE_ALLOWED`** (`test/unit/params_setup_test.lua:1007-1054` has only `removed`, `group_size` and `options`; the fixture test :1075-1085 fails on any inserted param). 0d adds 252 params, so it must add that kind; 1e then lists `scale_mask`, `tuning_name` and `tuning_tones` as added and `scale`'s options with `custom` appended (`options` kind exists).
- 0c: `test/norns_stubs.lua` (two argument checks; the engine spec may read `tuningMaxTones` etc. from the source, `stubs.engine_spec_from_source` around :430-500).
- 0a: room in `AGENTS.md` and the corrected `note_values` lines (`docs/notes/lua/notes.md:13`, `lib/notes.lua:351`, the facts' first wrong line), which 1e then need not touch.
- Wave 0's #772 fix in `lib/io/midi_out.lua`: lands first; 1e's bend edit is in `encoded` and `start_note`, apart from the zone setup paths #772 changes.

**Conflicts in wave 1** (land order 1a, 1b, 1c, 1e, 1d, design §14):
- `test/engine_check/variation.scd` and `docs/notes/engine/variation.md` are 1c's ("the grains and variation areas"); 1e must remove the 12-frame checks there. 1c lands first; 1e rebases its edit on 1c's file. Keep 1e's edit to :100-124 and the scale paragraph of the notes.
- `lib/engine/StrataVariation.sc` is 1c's (the arpeggiator's counter goes into `grainRate`'s interval pick, :41-45). 1e keeps `quantizedOffset`'s signature and does not edit the file.
- 1c's memory figures: 1c sets the grain def limit with today's quantize; 1e's one-UGen-shorter quantize moves each grain def by about a quarter KB (the facts' figure). 1e re-runs the memory area and updates the per-def figures if they are written as values.
- `lib/params_setup.lua`: 1a (fx defaults), 1c (the grain record lives in `lib/voices.lua`, but may add registrations), 1d (the source option), 1e (the hook and nothing else if the params come from the `scale` record).
- `lib/variation.lua`, `lib/sequencer.lua`, `lib/midi_in.lua`: 1d rereads every source test (`voice_uses_synth` at `lib/variation.lua:105`, `lib/sequencer.lua:406-417`, `lib/midi_in.lua:485-488`); one line each, and 1d lands after 1e.
- `test/norns_stubs.lua`'s checks table, `test/sync_check.lua`'s `PENDING_COMMANDS`, `test/engine_check.scd`'s `areaOrder`, `.github/workflows/test.yml`'s shards, `AGENTS.md`'s command rows: 0c, 1b and 1d add lines too (registration lines, keep both).
- `lib/constants.lua` `START_ORDER`, `docs/notes/lua/state-and-voices.md`'s table, `structure_test.lua`'s `start_steps()`: 3b and 4d add start steps later; pick distinct numbers now.
- `lib/pages/setup.lua`: 4d adds `factory sets` after 1e's row (wave 4).

**Gives later packages.** 2b (the arpeggiator) needs:
- `S.lib.variation.interval_set(voice_idx)` with its signature, returning semitones that may now be fractional (cents / 100), ascending for the chord set; and the interval send (`send_intervals_now`, :152-158) left in shape, since 2b owns "the interval send in lib/variation.lua".
- `S.lib.sequencer.degree_semitones` and the step chord path unchanged in shape (2b owns "the step chord in lib/sequencer.lua").
- Pitches already tuned at `S.lib.notes.play` (MIDI through `midi_note`, steps through degrees): a held chord's intervals from the own note are differences of tuned pitches and need nothing more.
- A range warning: a held chord wide enough (keys 36 to 96 is ±60 semitones) pushes a quantized grain past the table, where `Index` clips (section 5, point 2). 2b either clips its intervals or the table is widened now.
- 3b: `scale_mask` is a scene global, not a voice key; presets hold `quantize` only. Nothing else.
- 4d: the factory loader sets text params "to its default, a text param too" (§9): it can call `S.lib.params_setup`'s text default (`pset.text_defaults`) for `tuning_name` and `tuning_tones`.

**Rules touched.** `AGENTS.md:210` (per-sample loops; extend), `:253` (scale quantize; extend), `:233` (unchanged if `scaleBuffer` keeps its name), the #460 rule that the engine's start state equals the params' defaults (`docs_test.lua:487-528`; extend to the tuning), `docs/notes/lua/variation.md` Must not break :4 (the 0.8-semitone detent and "less than a scale step", false in dense tunings) and :6 ("The engine gets the scale only through `engine.setScale`": add the tuning's two commands).

## 4. Tests

### Existing tests that pin today and must still pass unchanged (the default's exactness)

Every one below must pass with the default tuning, unmodified; they are the proof that twelve equal gives 3.7's pitches exactly (integer cents / 100 are exact doubles):
- `variation_test.lua`: "chord follows the scale's degrees" (:147; 0,4,7,11 off; 0,3,7,10 minor; 0,4,9,14 pentatonic; root-independent), "a quantized freq moves by scale tones on slow encoder and arc turns" (:163, whole notes within 1e-6, never skips a C major tone), :213, :234, :272, :300, :322, "a MIDI note snaps to the scale for a quantized voice only" (:353), "scale and root are discrete scene globals that send setScale" (:378, exactly one `setScale` per change: the `scale_mask` action must send nothing unless `scale` is custom), :416, :439, :648, :699, :731, :743, :754, :767, :793.
- `midi_in_test.lua`: :64, :82, "MIDI note details: start order, exact pitch, clamping" (:99), :657, :686, :952, "a quantized voice's every note is snapped" (:969).
- `sequencer_test.lua`: :786, :855, "a note transposes the voice by scale degrees" (:868; :885-888 pin the chromatic shortcut, `degree_semitones(1, 2) == 2` within 1e-9 for a voice at 225 Hz, between notes), :1611, "a step's notes go through the scale once per step" (:2306; it wraps `seq.degree_semitones` and counts calls, :2312-2317, so the field must stay the one called), :2771, :3104 (:3114-3115).
- `samples_test.lua`: :404, :434, :453, :472-480 (walks the mask itself with `% 12`).
- `mutation_test.lua:471` (`variation.snap_note(whole) == whole`).
- `notes_test.lua` (`note_values` :101, :178, :705), `mpe_test.lua:92`, `io_targets_test.lua:94`, the jf/wsyn/txo/crow note tests: unaffected code.
- `docs_test.lua:492` (#460) and `:689` (`assert_engine_rejects("integer", "setScale", 0, nan)`).
- `engine_sync_test.lua:1650-1675` ("a voice start sends 3.7.0's messages", fixture `test/fixtures/3.7.0-start-calls.lua`): a voice start sends no tuning message, so unchanged.

### Existing tests re-based

- `structure_test.lua:995-1053` `start_steps()`: the tuning step and its engine calls; ":1160-1163" counts orders (automatic).
- `params_setup_test.lua:1007-1016` `PARAM_FIXTURE_ALLOWED`: `scale` options (`off`, 41 names, `custom`), and added `scale_mask`, `tuning_name`, `tuning_tones` (needs 0d's added kind).
- `pages_setup_test.lua`, if the row is appended after `transport` (index 13): :121 (`seen, 17` → 18, and "thirteen" → "fourteen"), :141 (`"mpe & zones,save scenes,load scenes"` → `"mpe & zones,save scenes,load scenes,scale & tuning"`), :150, :155, :202, :222 (`setup_cursor, 17` → 18). Unchanged: :41 (11, load scenes), :175 and :242 (`enc(2, 9)`), :42 (`enc(2, 4)`). In `lib/pages/setup.lua:431` the layout state "a 16x8 turned upright, the rotation fields" uses `enc(2, 12)` to reach the first rotation field: becomes `enc(2, 13)`. Inserting the row anywhere above `save scenes` moves far more (the index walk :25-41).
- `test/engine_check/variation.scd:100-124`: moved to `tuning.scd` (above).
- `docs_test.lua:487-528`: extended to the tuning.

### New Lua tests (proposed names and values)

`test/unit/tuning_test.lua`:
1. "the default tuning is twelve equal steps and plays 3.7's pitches": `count() == 12`, `period() == 1200`, `pitch_of_key(k) == k` for every k 0..127 and every root (exact equality); `snap(60.4) == 60`, `snap(60.5) == 60` (tie down), `snap(60.6) == 61`; with C major `snap(63.2) == 64`, `snap(63.0) == 62` (tie down) = today's `snap_note`.
2. "step walks the allowed tones as the degrees did": C major from 60: `step(60, 2) == 64`, `step(60, -1) == 59`; from 60.3: `step(60.3, 1) == 62`; from 69 with C major `step(69, 1) == 71`; within tone_tolerance (60.995) counts as on 61.
3. "equal_step is the tuning's step when every tone is allowed": 12 equal scale off 1; C major nil; 19 equal `12 / 19`; ji normal nil.
4. "a key maps in order from the root": 19 equal, root C: `pitch_of_key(61)` = 60 + 12/19, `pitch_of_key(79)` = 72, `pitch_of_key(59)` = 60 - 12/19; root D: `pitch_of_key(62) == 62`; Partch 43: key 0 is 43.29 and key 127 is 78.80 (two decimals).
5. "the mask applies only to twelve tones of an octave": ji normal + C major: `allowed()` = the seven major classes' cents; 19 equal + C major: all 19; twelve tones with period 1300: all 12; `scale_active()` true/false accordingly.
6. "the tuning reaches the engine as one setTuning and its tones, in order": selecting ji normal sends `setTuning(12, 1200)` then `setTuningTone(0, 0)` ... `(11, 1088.2687)` (4e-4 tolerance: text at four decimals); 43 + 1 messages for Partch.
7. "tuning_tones' text round-trips": `text_of(parse_text(text)) == text` for every built-in; a bad text (count 0, 129 tones, `1200 0 100 50`, `1200 5 100`, `99 0 50`, `abc`) prints one line, keeps the tuning and sets the param back silently.
8. "a PSET carries the tuning and applies it before the voices": select 19 equal, quantize voice 1, set its freq, write a PSET, select 12 equal, read: tuning back, voice 1's freq exactly the saved one (the #125 rule), `setTuning(19, 1200)` sent before any `v1_freq` send.
9. "a PSET without the tuning lines comes back in twelve equal steps, its quantized voices snapped again" (modeled on `params_setup_test.lua:741`, `without_lines`): a session in 24 equal with a quantized voice on a quarter tone; read a PSET without `tuning_name`/`tuning_tones`: both at their defaults, `setTuning(12, 1200)` sent, the voice's freq a whole note; a silent read sets both silently and sends nothing.
10. "the start sends the tuning before any voice starts": the start's calls hold `setTuning(12, 1200)` and 12 tones before the first `voiceOn`.
11. Built-ins: every entry's tones strictly ascend, start at 0, end below 1200, and match the cents table above to 1e-4; the names fit `name_max`.
12. Parser: accepts a file with comments, an empty description, `3/2`, `701.955`, `2` (= 2/1) and trailing text after a value; refuses (each with its reason) a count of 0 and 129, a missing pitch line, `-3/2`, `0/1`, `1e3`, `0x10`, `inf`, a descending pair, a repeated `1/1`, a period of 99 and 4801 cents, a file over `max_file_bytes`; Bohlen-Pierce (13 tones, `3/1`) accepted with period 1901.955.
13. "a file is listed from the tunings folder": two `.scl` files and a `.txt` in `_path.data .. "strata/tunings/"` list as the two; a missing folder lists none.

`test/unit/variation_test.lua`:
14. "custom is the last scale and scale_mask holds it": `scale` options end in `custom` (index 43); custom with `scale_mask` 1453 sends `setScale(root, 1453)`; `scale_mask`'s action sends nothing while the scale is not custom; both discrete scene globals (default 4095), applied at a fade's end.
15. "a chord in another tuning" (per the rule the planner picks, section 5, point 4).
16. "a quantized freq in a dense tuning moves about one tone a detent" (if the rule in point 9 is taken): 24 equal, quantized, from 440 Hz: each E3 detent moves exactly one quarter tone; in twelve equal the :163 case is unchanged.
17. "a MIDI key in 19 equal plays its degree": key 61 on a synth voice sets freq to `note_num_to_freq(60 + 12/19)`.

`test/unit/sequencer_test.lua`:
18. "degrees walk a tuning's tones": ji normal, C major, voice at middle C: degree 2 is +386.3137 cents (3.863137 st); 19 equal, scale off: degree 1 is 12/19 st from a detuned voice (the equal shortcut).

`test/unit/io_midi_out_test.lua`:
19. "an MPE note's bend carries its pitch's cents": MPE voice, bend range 48, a step note at pitch 60.3: `note_on 60`, `pitchbend round(8192 + 8192 * 0.3 / 48) = 8243` before it; a played note with a raw bend ratio `2^(1/12)` at pitch 60.3: `round(8192 + 8192 * 1.3 / 48) = 8414`; the express step resends with the same detune.
20. "a plain note sends its nearest key and no bend": pitch 60.6 → `note_on 61`, no pitchbend.

`test/unit/ui_scale_editor_test.lua`:
21. Opens from SETUP's row (K3) and closes with K2; E2 moves over root, scale, notes, tuning; E3 on root and scale edits the params; on the notes row E3 moves the class cursor and K3 toggles it: under Major, toggling F# sets `scale_mask` to 2741 + 64 = 2805 and `scale` to custom (mask first, then scale: one `setScale` with 2805); toggling the last class off is refused (the mask stays 1-4095).
22. The note tap: while open a MIDI note 66 (F#) toggles class 6 and plays nothing (`notes.play` not called); closing clears the tap; in 19 equal the tap takes nothing.
23. In 19 equal the scale and notes rows show `--` and E3/K3 there change nothing.
24. The tuning row: E3 moves a pending choice (dim), K3 applies it (one `setTuning` set); a refused file flashes its reason in the editor's own hint row.
25. Layout states (in `lib/pages/setup.lua`'s record, as `zones_editor_state`): the editor with the cursor on each row; `Gagaku Rittsu Sen Pou` (97 px, the widest musicutil name; right-aligned at 124 it starts at x 27, clear of `scale` at 0-21); all twelve classes in; the tuning row with the longest built-in (`meantone 1/4`, 58 px) and a long file name cut by `S.lib.ui_text.fit_text`; the 19-equal `--` state; a pending choice.

`test/unit/structure_test.lua`:
26. "the tuning table is built with Signal primitives (#131)": `per_sample_loops(sc_method_body(StrataScale.sc, "tuningTable"))` is empty.

`test/unit/docs_test.lua`:
27. "the tuning constants equal the engine's": `TUNING.max_tones`, `min_period`, `max_period`, `octave`, `octave_tolerance`, `root_key`, `table_frames`, `table_low`, `table_resolution` against the engine's methods; the engine's start tones and period equal `TUNING.default`.

### The engine check area `tuning` (test/engine_check/tuning.scd)

Each by `loadToFloatArray` of `engine.scaleBuffer` (as `variation.scd:101-106` reads the 12 frames today), plus one grain-level case:
1. "the table has `tuningTableFrames` frames and starts at twelve equal, chromatic from C": `numFrames`, `scaleRootAndMask == [0, 4095]`, `tuningTonesAndPeriod == [(0..11) * 100, 1200]`, every frame the nearest whole note to its center, a tie down, exact integers.
2. "the default table lands where 3.7's quantize lands": against `round(n) + 0` at every frame center but the frames at exact half semitones (205 of 2048 with the design's range), where 3.7 rounded up.
3. "setScale fills the table with the nearest tone of the scale": C major, D major (the mask from the root), each frame equal to the brute-force nearest allowed tone, tie down.
4. "setScale ignores a bad root or mask" (moved from `variation.scd:119-123`), the table unchanged.
5. "a 19-tone tuning": `setTuning(19, 1200)` and 19 tones: every frame within 1e-4 of the nearest 19-EDO pitch from C4 (but midpoints); `setScale(0, C major)` under it changes nothing.
6. "a mask in a twelve-note tuning": ji normal with C major: frames on the JI major tones; twelve tones of a 1300-cent period with the mask: every tone allowed.
7. "an incomplete or bad set keeps the old tuning": 11 of 12 tones; out-of-order arrival completes; a set that does not ascend, a tone 0 that is not 0, cents at the period; `setTuning` with count 0, 129, period 99, 4801, nan; `setTuningTone` with no set begun or an index past the count. Each leaves the table as it was.
8. "the table's bufnum never changes" across every case.
9. Grain level (needs the timecode probe of `variation.scd:20-92`; copy or move it into `h`): a quantized voice in 19 equal with jitter 6 lands every grain within 0.03 semitones of a 19-EDO tone.

Memory area: no limit changes; re-run and re-read the grain defs' sizes after the quantize change.

## 5. Risks and open points

1. **Nearest allowed tone is not 3.7's quantize in a masked scale.** 3.7 rounds to the whole note first, then moves that note to its class's nearest tone, a tie down (`StrataScale.sc:135-139`, `:100-106`); the design says each frame holds "the nearest allowed tone" (§6.2). Measured over the 2048 frames: chromatic, they differ only at the 205 exact-half frames; **C major, they differ at 378 frames (18 %)**: e.g. pitch 63.2 lands on E (64) where 3.7 put D (62), because 3.7's two-step rule pulls a whole-tone gap's middle semitone down. Only a quantized voice with jitter, a fractional pitch shift or a bend before the quantize hears it (a quantized freq is already a tone). The new rule agrees with Lua's `snap_note` (`lib/variation.lua:78-86`, which already finds the true nearest from a fraction, unlike the engine). The two-step rule can be built too (nearest tuning tone, then that degree's allowed tone: the same Signal loop counted by degree). The planner picks; either way the changelog names it, and §13's "the default table lands where 3.7's quantize lands" holds only for the chromatic table.
2. **The table's range is the synth voices'.** -45 to 159.7 covers a synth voice's freq (15.5-95.2) ± 24 pitch ± 12 jitter ± 24 interval. A buffer voice's `scaleNote` is its file's key (0-127, `lib/samples.lua:405`) plus `ratiomidi(bufRate)` (0.25-4, `lib/voices.lua:402-403`, ±24, `StrataScale.sc:43-49`), an extra buffer note's is the reference plus its rate (`StrataScale.sc:54-56`), and `pitchShift` is clipped to 0.25-4 (`StrataModulation.sc:189`): together -84 to 211. Past the table `Index` clips, so the grain lands on the edge tone and plays up to 50 semitones off (3.7's mod-12 had no edge). 3072 frames from -90 (12 KB of RAM, a 15.4 KB message) or 4096 from -100 (16 KB, 20.5 KB) covers it; 2b's held chords may widen it further. Recommend 4096 from -100 and naming the computed range in the notes.
3. **`custom` reads as off.** `current_scale()` (`lib/variation.lua:48-52`) indexes `musicutil.SCALES[index - 1]`, nil at index 43; `scale_mask()` and the chord would silently use the chromatic set unless they test for custom first.
4. **The chord set from `allowed()`** (design §6.1 "degrees 1, 3, 5 and 7"): in twelve equal it equals musicutil's for 40 of the 41 scales (`chord.lua`); In Sen Pou changes from 0,5,8,13 to 0,2,8,13 (musicutil lists its intervals unsorted, `musicutil.lua:54`). With the scale off, degrees 1-7 of the twelve allowed tones are 0,2,4,6, not 3.7's `chromatic_chord` 0,4,7,11 (`lib/variation.lua:27, 135`): keep that rule ("scale off: degrees 0, 4, 7, 11 of a twelve-tone tuning"). In a tuning that is not twelve tones, degrees 1, 3, 5, 7 of the whole tuning are a cluster (19 equal: 0, 126, 253, 379 cents). Options: the cluster as written; the allowed tones nearest 0, 400, 700, 1100 cents; or the chord set inactive there. The design is silent; the planner picks.
5. **Degrees with the scale off keep a detuned voice's offset** (`lib/sequencer.lua:431`, pinned by `sequencer_test.lua:885-888`). `step` alone would give 1.7 for degree 1 from 60.3. The `equal_step` shortcut keeps it for any equal division with every tone allowed.
6. **Text params, as norns has them.** `Text:set` bangs only on a change (`~/src/norns/lua/core/params/text.lua:30-35`), so a PSET whose tuning equals the session's runs no action (fine). A silent read sets the hook's defaults silently, so the engine keeps the old tuning until the next change (the hook's general semantics). norns writes `"%s: %s\n"` raw (`paramset.lua:514`) and reads the rest of the line after `:%s*` (`:545`): a name must hold no newline and loses leading spaces; a value of `inf` or `-inf` would become a number (`:560-563`; not reachable). The shown `tuning_name` is editable in PARAMETERS through norns' text entry (`core/menu/params.lua:195-198`): its action must only rename. Text params get no redraw from `redraw_on_param_changes` (`lib/params_setup.lua:748`).
7. **The period range.** The parser must refuse periods outside 100-4800 cents (the engine's), not only "0 or less" (design §6.4). Scala allows non-ascending pitches (from memory); the design refuses them. Unsure: blank lines among pitches, a count line with trailing text, negative cents inside the period.
8. **The start send is redundant by #460's rule.** The engine's alloc tuning equals Lua's default and every change sends; norns never loads a PSET before `init` returns. The design asks for the send (§6.2, §13). It costs 13 messages at every start. Either way, extend the #460 docs test to the tuning.
9. **The quantized `freq` turn in a dense tuning** (left to the builder). One detent is `quantum` 0.01 of the 20-2000 Hz exp range = 0.797 semitone (`lib/ui/detent.lua:90`, `lib/params_setup.lua:971`); one arc tick 79.7 / 1024 = 0.078 semitone (`ARC_TICKS_PER_SWEEP` 1024, `lib/constants.lua:86`; `docs/notes/lua/variation.md:4` says 0.16: unsure which is right). The filter sees only the value, the stored value and `turned` (`lib/variation.lua:204-210`); it cannot tell a detent from a tick. Options the code allows: (a) leave it: 24, 31 and 43 tones skip tones on E3, ALT+E3 (0.08 st) and the arc reach every tone; document it. (b) Scale the shadow's travel by `min(1, mean allowed step / one detent's travel)`, the detent computed from the freq spec: one detent about one tone in a dense tuning, the arc proportionally finer, **twelve equal and every musicutil scale unchanged** (mean step at least 1 semitone > 0.797), so `variation_test.lua:163` passes as is. (c) A step per turn (`step(returned, sign)`): breaks the arc (one tone a tick) and the :163 test. Recommend (b).
10. **The editor's hint flash.** While a modal owner is up, `redraw()` takes its hints from the owner and never from `S.lib.ui_flash.text("hints")` (`strata.lua:320-326`): a refused file's reason must come from the editor's own `hints`.
11. **One note tap.** `S.lib.midi_in.set_note_tap` holds one function (`lib/midi_in.lua:54-55, 178-181`); `reset_midi_input` clears it without telling its owner (:227-232), as it does to the zones editor's learn. The editor re-arms the tap (or reads it back) on each draw, or midi_in gains a hook; the planner picks. SETUP's key handler does not run under a modal owner, so the two editors are never open together.
12. **The notes row's width.** Twelve names with sharps are 129 px (`C C# D D# ...`); `C#` is 10 px, `D#` 11 (`test/norns_stubs.lua:2453-2460` advances). Cells of 8 px from x 28 fit single glyphs only: a natural's letter, `#` for a sharp, `.` for a class out of the scale, the cursor's full name elsewhere (the hint row). The design's sketch (`D . E F . G . A . . C .`) shows only naturals; check the render with `test/render_pages.py`.
13. **The editor's tuning row**: "steps through the built-ins, then the files" (§6.4). Applying on every E3 detent would send up to 129 messages and re-snap every quantized voice per detent; a pending choice applied by K3 (or after a rest, as VOICE's `type` row does with `TYPES.settle_seconds`) is the builder's call. List the folder once at open (`util.os_capture` runs a shell, `lib/files.lua:61`).
14. **MPE step notes on a shared channel send no bend** (`lib/io/midi_out.lua:318-322`: "on a shared one it takes the channel as it is"), so such a note loses its cents. Plain mode and nb keep the nearest key (design §6.5); `docs/user/io/midi-out.md:21` and `nb.md:17` gain one sentence each.
15. **Float32.** Engine `"f"` arguments and the buffer are float32: a JI tone sent from Lua's double lands within about 6e-5 cents, the table within 1e-5 semitones (measured, above). Lua-versus-engine comparisons need a tolerance; twelve equal is exact.
16. **`fixedBufferBytes`** (0b) counts four buffer sets; the table (8-16 KB) is not one of them and is negligible against the 1 GB the high tier leaves. Say so in the notes rather than edit 0b's figure.

## For the planner

1. **The design's "nearest allowed tone" changes 3.7's masked quantize at 18 % of the table's frames** (C major: 378 of 2048, measured in sclang; chromatic only at the 205 half-semitone frames). Decide nearest (agrees with Lua's `snap_note`) or 3.7's two-step rule before the engine step; §13's tuning check wording follows.
2. **2048 frames from -45 do not cover buffer voices**: their quantized pitch reaches -84 to 211 (`StrataScale.sc:43-56`, file keys 0-127, rate and pitch ±24), and `Index` clips to the edge tone. Use 4096 from -100 (16 KB RAM, one 20.5 KB `/b_setn` under the 65504-byte packet).
3. **The table builds with Signal primitives in under a millisecond, and must be sent as one Array message**, not `Buffer.setn` (whose `setnMsgArgs` loops per value in sclang, `Buffer.sc:421-437`); construction and probe in section 2.
4. **1e must edit 1c's `variation.scd` (:100-124, the 12-frame checks) and its notes**; 1c lands first. Keeping `quantizedOffset`'s signature keeps 1e out of `StrataVariation.sc`.
5. **The params fixture test has no "added" kind** (`params_setup_test.lua:1020-1041`); 0d must add one, and 1e lists `scale_mask`, `tuning_name`, `tuning_tones` and `scale`'s appended option.
6. **`custom` at index 43 reads as "off"** through `current_scale()` (`lib/variation.lua:48-52`) unless `scale_mask()` and the chord test for it.
7. **The chord set and the scale-off degrees need explicit rules**: degrees of `allowed()` give 0,2,4,6 with the scale off (3.7: 0,4,7,11) and a cluster in 19 equal; `degree_semitones`' chromatic shortcut (pinned at `sequencer_test.lua:885-888`) needs an `equal_step` rule.
8. **Recommend the shadow-travel scale for dense tunings** (`min(1, mean step / 0.797 st)`): twelve equal and every musicutil scale unchanged, so `variation_test.lua:163` stands.
9. **`AGENTS.md:183`'s "the last fourteen rows" breaks when command rows are appended**; one placement rule for all 3.8's new rows. 1e's edits total about 150 words.
10. **Appending the SETUP row after `transport` re-bases six assertions** (`pages_setup_test.lua:121, 141, 150, 155, 202, 222`) and one layout state (`lib/pages/setup.lua:431`, `enc(2, 12)` → 13); any higher place moves the index walk at :25-41. Start step: propose `START_ORDER.tuning = 55`, leaving 112-119 to 3b and 4d.

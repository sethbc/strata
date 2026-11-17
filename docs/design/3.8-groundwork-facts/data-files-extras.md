# Facts: the data files and `extras`

Read-only survey of `main` at 3bb75daa. Counts are from `grep` and from one scratch Lua run of the test harness's `load_strata()` (it dumped `S.registry`; nothing tracked was changed). Paths are relative to the repository root.

## 1. The ten data files

Every one is read only through `S.lib.data_files.read` and written only through `write` (`docs/notes/lua/data-files.md:3-9`). So each has the same limits: 4 MB (`max_bytes`) and 32768 tables (`max_tables`, `lib/data_files.lua`). The largest scenes file is 7474 tables (`docs/status.md:35`). All ten live in `data/strata/`.

| File | Owner | Version | Holds | Scope | Read / written | Unusable file | Added |
|---|---|---|---|---|---|---|---|
| scenes.data | lib/scenes.lua:1014 | `SCENE_DATA_VERSION` 8, floor 7 (constants.lua:11,15) | 16 scenes | script | start, `load scenes`; each scene save, cleanup (scenes.lua:1042) | set aside `.bak` (1073-1092) | 2.x (versioned at 3.0, CHANGELOG:1083) |
| buffers.data | lib/buffers.lua:891 | `BUFFER_DATA_VERSION` 3, floor 2 (constants.lua:16,26) | per slot: path, start, a take's settings (buffers.lua:914-920) | script | start; 0.1 s after a change burst, cleanup | set aside `.bak` | 3.0 (CHANGELOG:968) |
| macros.data | lib/macros.lua:44 | 1 | the macro targets | live file + one per PSET | start; 0.1 s burst, cleanup; PSET write | set aside `.bak` | 3.4 |
| matrix.data | lib/matrix.lua:49 | 1 | the 16 routings (source, destination) | live + per PSET | same, 0.1 s | `.bak` | 3.4 |
| gestures.data | lib/gestures.lua:48 | 1 | 4 recorders' event lists (param id, value, times) | live + per PSET | same, 0.1 s | `.bak` | 3.4 |
| sequences.data | lib/random_sequences.lua:36 | `RSEQ.data_version` | 4 random sequences' values | live + per PSET | same, 0.5 s | `.bak` | 3.7 |
| samples.data | lib/samples.lua:26 | 1 | per file (path and start): tempo, key, normalize, slices; at most 256 entries, least recently used dropped | script | start (468); 0.1 s burst, cleanup (503) | `.bak` (476) | 3.7 |
| grids.data | lib/grid/core.lua:585 | 1 | each grid port's rotation | script | start; each `set_rotation` (682) | rotation 0, replaced at the next change, no backup | 3.3 (CHANGELOG:556) |
| notes.data | lib/notes.lua:32 | 1 | the note pool | script | start (946); `set_pool` (846) | tier default, replaced, no backup | 3.5 |
| io.data | lib/io/rig.lua:19 | 1 | the rig settings (ii bus, controller and remote ports, OSC) | script | start (168); each set, cleanup (187) | `.bak` (176) | 3.6 |

**Data file and side file.** Every file above is a "data file": parsed by `decode`, written atomically by `write`, a backup never replacing another (`docs/notes/lua/data-files.md:3-12`). A "side file" is the four modules' second copy. Each of them has a live file plus `<pset path without .pset><side_suffix>` beside each PSET, made by `S.lib.side_files.new(spec)` (`lib/side_files.lua`, 157 lines; notes 47-59). The PSET hook writes the side file at every PSET save (empty too), reads it after every PSET load and deletes it with the PSET (notes:57). The side-file modules are macros, matrix, gestures and sequences. The other six have no per-PSET copy.

**The floor rule** applies to scenes and buffers only (notes:12): a file from the floor up loads with its missing fields filled; one below the floor or newer than the build is set aside. The other eight accept exactly version 1 (or `RSEQ.data_version`).

**Not among the ten:** `performance.data` and `performance_active.data` (lib/performance.lua:20-21), the engine's peaks, onsets and scratch takes, and the `.pset` files.

## 2. What goes where

- **The PSET** (norns' `params:write`) holds every saved param: 1113 params have ids (harness count), including each voice's built-in and registered params, the globals, `buf<n>_file` and the PSET-only groups. `buf<n>_file` is a norns file param, saved by default (`~/src/norns/lua/core/paramset.lua:180,513`), and its action loads the file (lib/params_setup.lua:668-669).
- **scenes.data** holds per scene: 154 global fields (`S.SCENE_GLOBAL_PARAMS`, 65 of them registered), ten blocks (`strata_lfo1..6_dest_key`, `macros`, `sequences`, `matrix`, `steps`), and per voice `active`, `source`, `params`, `grain`, `crossmod`, `extras`, plus `frozen[i]` and `patterns[i]` (scenes.lua:323-385). Scenes are one file per script, not per PSET (scenes.lua:1014-1015).

**State stored more than once:**
- A slot's file path is in the PSET (`buf<n>_file`) and in buffers.data. The start point is only in buffers.data. A path whose folder has shell characters is only in buffers.data (`docs/notes/lua/buffers.md:16`).
- Macro targets, matrix routings and random sequences are each in three places: the live file, the PSET's side file and every scene's block. A recall applies the block and rewrites the live file (macros.lua:723-735, matrix.lua:695-716, random_sequences.lua:265-276).
- A take's settings are in buffers.data (`settings`) and in samples.data once saved (`S.lib.samples.stored_own`, buffers.lua:917).

**Cross-file references and how a mismatch is handled:**
- Scenes name buffer slots by index (`source` 2-9), never by contents (scenes.lua:345). A recall plays whatever the slot holds.
- Scene macro targets, routings, LFO destination keys and gesture events name param ids. An unknown macro or matrix id is kept, not played, and named on the console (macros.lua:480-494, matrix.lua:512-528). An unknown LFO key reads as none, with a console line (lfos.lua:976-995). Gesture events are only checked for shape (gestures.lua:647-670).
- An unknown key in a scene's `params` or `extras` makes the scene invalid (scenes.lua:1256, 1275; decision `docs/decisions/3.2.md:11`). `validate_scene_data` then fails the whole file, and it is set aside (scenes.lua:1129-1131).
- samples.data is keyed by path and start, and is applied when a file is bound to a slot (`docs/notes/lua/buffers.md:21`).

## 3. Candidate 3 was built in 3.7

Plan ruling 30 (`docs/decisions/3.7.md:69`) and package 0d deleted the conversions. A structure test fails on a version compared below its floor (decisions:103). CHANGELOG.md:10 says files older than 3.5's scenes and 3.3's buffer lists are set aside, no `.v<n>` copies are kept, the PSET has no format line and the LFO import and MIDI map repair are gone.

- `migrate_scene` and the `scene_migrations` registry no longer exist (no match under lib/).
- `fill_scene` (scenes.lua:286-321) is the one generic fill; `validate_scene` (1201-1290) refuses unknown keys, never drops them. Only loops has a `normalize_scene` (loops.lua:109).
- buffers.data loads versions 2-3 (buffers.lua:1000-1019). `migrate_read_pset` keeps only #628's defaults and #554's rounding (params_setup.lua:213-240).

## 4. `extras`

**The mechanism:**
- **The record:** `S.register_voice_params(record)` (state.lua:196-251). Its fields are `name`, `count`, `add`, `add_first`, `grain_keys`, `sync`, `scene_defaults` (a table or a function of the voice), `discrete`, `scene_ranges`, `voice_rows`, `layout_states`, `normalize_scene`, `fader` and `randomize` (state.lua:151-153, 172-195).
- **The param:** `add_voice_extra(voice_idx, record, key, param)` (params_setup.lua:805-842) gives the id `v<i>_<key>`. Its action rounds whole numbers, runs `filtered_value`, stores in `S.voices[i].extras[key]` and calls `note_param_edit` and `send_param_to_engine`. A `grain_keys` entry gets a `setGrainParam` sender. Other engine paths are the record's own (`sync`, extra senders such as notes.lua:917).
- **Fader and order:** `fader = true` is refused (state.lua:246). The params are added after crossmod, under a `voice <i> extras` separator (1188-1191); `add_first` comes before the synth params (#125).
- **LFO destinations** are registered separately by suffix (state.lua:332; history.lua:78, voice_mix.lua:215).

**Today:** 12 records and 53 params per voice, 371 in all. 51 are scene keys; `solo` and `note_cap` are not.

| Record (module) | Params | Keys |
|---|---|---|
| history (history.lua:77) | 1 | history |
| freeze (freeze.lua:130) | 2 | freeze, freeze_mode |
| loops (loops.lua:161) | 2 | loop_start, loop_length |
| variation (variation.lua:358) | 12 | quantize (add_first), intervals, custom_interval_1-5, interval_prob, pitch/size/pan_jitter, reverse |
| voice_mix (voice_mix.lua:213) | 8 | filter_type/freq/res/mix, delay_send, reverb_send, mute, solo |
| bookmarks (positions.lua:911) | 4 | bookmark_1-4 |
| scan (scan.lua:256) | 2 | scan_mode, follow |
| envelopes (envelopes.lua:335) | 6 | env_attack/decay/sustain/release/curve/loop |
| notes (notes.lua:934) | 3 | note_cap, attack, release (per-voice defaults) |
| expression (expression.lua:522) | 4 | press/slide target and depth |
| slices (slices.lua:507) | 1 | slices |
| seq (sequencer.lua:1700) | 8 | seq_length, division, direction, misstep, swing, gate, gate_length, gate_release |

Each voice also has 14 `v<i>_` params that are in neither group: 11 `v<i>_out_*` (IO targets) and 3 `v<i>_zone*`. They are PSET-only.

**Built-in compared with extras:**

| Concern | Built-in (`params`, `grain`, `crossmod`, `source`) | Extras |
|---|---|---|
| Defaults | the `voices` table per voice (voices.lua:17-250) | each `add`'s param spec; `scene_defaults` repeats them |
| Spec | `get_param_spec(key)`, a table keyed by param name and shared across types (params_setup.lua:1199-1227); grain and crossmod specs inline | inline in each record's `add` |
| Action | hand-written per param in `add_voice_params` (params_setup.lua:903-1193) | one generic action (805-842) |
| Engine sync | `send_synth_params`, `send_grain_params`, `send_crossmod_and_bend` (engine_sync.lua:720-755) | `send_registered_voice_values` (697-711) |
| Scene shape | nested `params`, `grain` (keys mapped by `GRAIN_PARAM_IDS`, constants.lua:130), `crossmod.slotN` | flat `extras[key]` |
| Fill | `VOICE_SCENE_DEFAULTS` (scenes.lua:127-134) | `registered_voice_scene_keys` (140-149) |
| Validation | key in `S.voices[i].params`; `GRAIN_PARAM_IDS` | key registered; `discrete` and `scene_ranges` |
| Recall | pairs order; grain `env` and `mode` discrete | sorted keys; `discrete` set at the end (scenes.lua:466-484) |
| MAIN randomize, mutation | synth params except amp, grain and buffer keys (mutation.lua:197-217, 330-375) | never |
| Page randomize (ALT+K2) | `VOICE_DRAWS`, synth draw | the record's `randomize` (pages/voice.lua:196-206) |
| 256 faders | `param_order`, grain keys, crossmod (grid/faders.lua:45-65) | refused |
| LFO destinations | per voice: main (through `MAIN_PARAMS`) plus 7 grain and buffer keys (lfos.lua:103-107); other synth params are not destinations | registered: history, filter_freq, delay_send, reverb_send; voice_mix also registers the built-in `amp` |
| Macro and matrix targets | derived from the LFO destinations (macros.lua:126-139, matrix.lua:95-112) | same |
| VOICE rows | `section_keys` (ui/voice_rows.lua:24-49) | `voice_rows` sections (51-) |
| Step locks | pos, pitch and size only (sequencer.lua:66) | bookmark |
| MIDI map, OSC `/param/<id>` | by param id | same |

**Code that treats the two kinds separately:**
- `.extras` appears 32 times in 14 files: scenes 8, variation 5, params_setup 4, voice_mix, sequencer, notes and envelopes 2 each, and one each in state (a comment), slices, loops, freeze, expression, engine_sync and buffers.
- The sequencer adds a local `extras(voice)` helper used 8 more times.
- `registry.voice_params` or `voice_scene_defaults` appears in 6 files (16 uses).
- The built-in side: `voices[..].params` 17 uses in 9 files, `.grain.` 38 in 5 and `.crossmod` 17 in 3 Lua files.
- Tests: `extras` appears in 22 files (145 lines). Registry use is in 15 files, 52 lines of them in registries_test.lua.

## 5. A voice preset today

No function yields one voice's scene state. `capture_scene` builds all seven inline (scenes.lua:323-385). `scene_entries` tags per-voice entries with `voice` (448-490, `entry_voice` 494). Blocks and globals carry no voice, and the `steps` block holds every voice's attributes.

**In the voice's own tables:**
- `params`: 3-7 by type.
- `grain`: 9 keys, including `buf_pos`, `buf_rate` and `buf_scan`.
- `crossmod`: 3 slots plus speed. The sources name other voices.
- `extras`: 53, including `mute` and `solo`.
- Several extras are relative to a slot or a pattern: loops, bookmarks, slices and seq.

**Elsewhere:** `source`; the slot's audio, path and start (buffers.data, the PSET); the file's settings (samples.data); `S.patterns[i]` and `S.pattern_steps[i]`; `S.frozen[i]`; LFOs aimed at the voice (global `strata_lfo<n>_dest_key`); matrix routings to a `v<i>_` id or from `EN<i>` (envelopes.lua:377); macro targets on `v<i>_` ids; the 14 IO and zone params.

## 6. What a selectable voice type meets

- **Engine:** the voice's def is fixed by index: `voiceSynthDefs` (StrataVoices.sc:24), used in StrataLifecycle.sc:10,164-165 and StrataNotes.sc:260,528. `noteMainRanges` is keyed by def name (StrataVoiceDefs.sc:59-61).
- **Lua's voice table:** the type is `S.voices[i].name`, with its own `param_order` and `params` (voices.lua). `MAIN_PARAMS` is keyed by name (constants.lua:148-156), read in pages/main.lua:85,100 and pages/voice.lua:91,133.
- **Params:** they are added once at init from that voice's `param_order` (params_setup.lua:918-937), so `v<i>_<key>` ids, PSET lines, MIDI maps and OSC follow the fixed type. Specs are by param name and shared (`ratio` for FM and Ring; `mod` for Folder and Ring).
- **Scenes** key synth params by name under `voices[i].params` and validate them against `S.voices[i].params` (scenes.lua:1256). A scene holding another type's keys fails, and with it the whole file.
- **Per-index defaults:** notes' attack and release defaults are per voice index, matching each def (`NOTES.envelope`, notes.lua:43). `PULSE_RES` (constants.lua:20) is tied to `\strataPulse`.
- **Engine refusals:** `setVoiceParam` refuses engine-owned names only (StrataVoices.sc:51-53).
- **Unsure:** whether the engine memory check measures each voice def by index (not read).

## 7. What each alternative would touch

- **(a) Leave and map:** docs only. `docs/notes/lua/data-files.md` (61 lines) and `state-and-voices.md` (its `extras` line 37 lists 5 of the 12 records), `docs/notes/lua/params.md:118`.
- **(b) One per-voice value table:**
  - Code: the `.extras` uses (section 4); `add_voice_params`' hand-written built-ins (params_setup.lua:903-1193, about 290 lines); the scene shape in `capture_scene`, `fill_scene`, `scene_entries` and `validate_scene`; `VOICE_SCENE_DEFAULTS`; the three engine_sync senders; voice_rows' `section_keys`; mutation's `voice_spec`; faders; and `register_voice_params` (state.lua:151-251).
  - Scene format: a reshape is a new `SCENE_DATA_VERSION`. Under ruling 30 a reshape is no fill, so it means either a raised floor (setting 3.5-3.7 files aside) or a conversion the structure test would have to allow. `test/fixtures/3.6.0-files.lua` (3305 lines) and system_37_test.lua assert that 3.6 files load. The table count changes: today 7 nested tables per voice plus 1 for `extras`. `largest_scenes_tables` would then be re-measured.
  - PSET ids are unchanged, since both kinds use `v<i>_<key>`.
  - Tests: registries_test (1224 lines, 40 tests), scenes_test (3399, 105), engine_sync_test, pages_voice_test, the 22 `extras` files.
- **(c) Fewer data files:**
  - Natural groups: the device settings (grids, notes, io: all version 1 and per script, but grids and notes replace an unusable file without a backup while io sets it aside) and the four side-file modules (one helper already). A merge puts each group behind one version, and a damaged merged file sets aside every part at once.
  - Test lines naming each file: buffers 110, scenes 101, samples and io 19, gestures 16, macros and notes 11, matrix 10, grids 9, sequences 5.
- **(d) One container per PSET:** norns writes the `.pset` itself, and Strata only hooks `action_read`, `action_write` and `action_delete` (params_setup.lua:247-275). The container would replace four side files and their suffixes. Scenes are per script today, so making them per PSET changes the scenes file's own path and load rules (scenes.lua:1014-1200) and SETUP's status rows.

## 8. The factory presets' installer today

No installer code exists (no "factory" or "install" under lib/). No Lua copies files. The only shell use is `ls` in lib/files.lua:61, and the engine renames through `renameIntoPlace`. To install "scenes, a PSET with side files, samples" it would have to:

- **Scenes:** write them, but the only scenes path is `data/strata/scenes.data` (scenes.lua:1015). There is no import, bank load or second path. "Never overwrite a player's scenes" leaves only the first run with no file.
- **The PSET:** place `data/strata/strata-NN.pset` (norns' naming; `path_base` per `docs/notes/lua/params.md:92`) with `.macros.data`, `.matrix.data`, `.gestures.data` and `.sequences.data` beside it. The PSET's `buf<n>_file` lines load the samples on read, and `io_keyed` reads keys from the PSET's text (io/keyed.lua:88-100).
- **Samples:** copy audio under `audio/`. Their tempo, key and slices live in samples.data by path and start (256 entries, least recently used dropped), so they must be merged into it or be lost. buffers.data rewrites itself on load. The engine writes the peaks and onsets.
- **Unsure:** whether the PSET number must avoid the player's (norns lists PSETs by number), and how 4.0's design places files (undecided, ROADMAP.md:180-184).

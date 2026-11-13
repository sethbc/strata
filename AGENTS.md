# AGENTS.md

This file gives coding agents guidance for working in this repository. It is an index: the rules every change needs, the engine command interface and how to run the checks. Each module's details are in its own notes file (see the module table): read that file before changing the module.

**Keep this file short**: every agent loads all of it, and a test fails above 8,000 words. A rule here is one or two lines naming the notes file whose "Must not break" list holds the detail; history belongs in `docs/history.md`, and how something works in its module's notes.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It has seven synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring), each with its own granular processor. Any voice's grain stage can read one of eight stereo sample buffers (recorded, overdubbed, looped or loaded) or the live input instead of its synth. A filter, sends, a step gate and a mute per voice, a master filter, delay and reverb, six LFOs, sixteen macros, a scene morph, gesture recorders and a modulation matrix, a sequencer with a clock per voice, MIDI input, sixteen scenes, a nine-page screen UI (MAIN, VOICE, SEQ, FX, LFO, MOD, BUFFER, SCENES, SETUP), grid and arc complete it. Everything is playable from the norns alone, and a performance setting gives a Pi 4 a high tier (longer buffers, spectral freeze, the FDN reverb). The current release is 3.4.0 (see CHANGELOG.md).

**Where things are documented:**
- `docs/status.md`: **read first.** The open items (with GitHub issues) and the limits to plan around. Update it at the end of each piece of work.
- `ROADMAP.md`: the order and scope of the coming releases, and what has shipped. `docs/history.md`: each release in a paragraph, and how it was built. CHANGELOG.md: every change of every release.
- docs/design/: one design per release (`docs/design/3.4-design.md`, ...), written before its code and history once it ships. `docs/design/3.0-design.md` is still the reference for behavior; where the code differs, CHANGELOG.md's 3.0 "Deviations from the design" and later entries say how.
- docs/decisions/: the decisions taken during development, one file per release line, each with what it costs if wrong (`docs/decisions/README.md`). Add a release's decisions there.
- docs/notes/lua/: the Lua notes, one file per module (the module table below names each). Each opens with "Must not break", then what the module owns and how it works.
- docs/notes/engine/: the engine notes, one file per area of the engine check, each opening with "Must not break":
  - `docs/notes/engine/structure.md` (signal flow, the areas, the check's areas and helpers, SynthDefs, buses, node ordering), `docs/notes/engine/voices.md` (crossmod, `voiceOn` sync, retrigger and accent, pitchbend), `docs/notes/engine/grains.md` (the grain params, audio sources), `docs/notes/engine/lifecycle.md` (replace-never-stack, the kill fade), `docs/notes/engine/memory.md` (real-time memory), `docs/notes/engine/performance.md` (the tier values);
  - `docs/notes/engine/buffers.md` (the polls, buffer commands, fade before zeroing), `docs/notes/engine/files.md` (file writes, `.part` files), `docs/notes/engine/record.md`, `docs/notes/engine/waveform.md` (the peak buffers), `docs/notes/engine/positions.md` (the scan phase), `docs/notes/engine/loops.md` (loop regions);
  - `docs/notes/engine/effects.md` (filter, delay, reverb, master), `docs/notes/engine/mix.md` (the per-voice mix stage), `docs/notes/engine/rings.md` (the voice and input rings), `docs/notes/engine/freeze.md`, `docs/notes/engine/variation.md` (the per-grain draws, the scale), `docs/notes/engine/modulation.md` (3.4's fast modulation, the stage's step gate and mute), `docs/notes/engine/notes.md` (3.5's note slots and pool).
- `docs/checks.md`: how to run every check, what each needs, and CI.
- `docs/notes/test-harness.md`: how the test harness works (the stubs, the runner, the engine check's runner).
- `docs/workflow.md`: how a session runs work packages through agents (the skills at each step, the controller, workers and reviewers, the ledger, briefs, reports, landing, a release's steps).
- README.md: a short overview, quick start and index of the user documentation, which is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, `docs/user/arc.md`, `docs/user/params.md`, ...).

## Architecture

The project is written in two languages that must stay in sync:
1. **`strata.lua` and its `lib/*.lua` modules** (the norns script): UI, params, encoders/keys, grid, arc, MIDI and LFOs. They control the engine through `engine.*` commands.
2. **`lib/Engine_Strata.sc` and its `lib/engine/Strata*.sc` class extensions** (the SuperCollider engine): all synthesis and audio processing. It exposes commands with `this.addCommand()`. `lib/Engine_Strata.sc` holds only the class, every variable, `*new` and a generic `alloc` and `free`; all other code is in `lib/engine/` (the module table lists the files).
   - The engine is built from **areas**: one `strataArea<Name>` method per area, returning an Event of hooks (`allocState`, `addDefs`, `addCommands`, `start`, `stop`, `free`, `effectKeys`, `grainDefs`, `grainParamHandlers`) and an `order` (performance 10 to notes 170, in tens). `alloc` runs them in ascending `order` and `free` in descending order, every `stop` before any `free`, so every node is freed before any bus or buffer: a node never goes in `free`, a bus or buffer never in `stop`. An area keeps new state in `areaState[\<name>]`. Details: `docs/notes/engine/structure.md` (Areas).
   - Engine files are named `Strata*.sc` and extension files add methods only, never variables. Renaming or deleting an engine file needs a norns restart note in the changelog fragment.

```
Voice Synth → Voice Bus → Ring Writer → Voice Ring → strataGrainRing → Synth Path ┐
                                                                                   ├→ strataVoiceMix (voice filter, level on the other path, sends) → Main Bus (dry) + Delay Send + Reverb Send → Filter ×3 → Delay → Reverb → Master (drift/limiter/saturation) → Output
Buffer source:  Buffer pair (L/R) → strataGrainBuf → Other Path ──────────────────┤   (the stage mirrors the other path to the Voice Bus → Mod Synth, and writes the voice tap)
Input source:   SoundIn → strataInput → Input Bus → Ring Writer → Input Ring → strataGrainRing → Other Path ┘

Voice Bus → Mod Synth → Mod Bus → Other Voice Synths (cross-modulation, 3 slots per voice)
```

### Modules, notes and tests

In include order. Unit test files are under test/unit/ (one per module).

| Module | S.lib name | Notes | Unit tests |
|--------|--------------|-------|------------|
| `strata.lua` (entry points) | | `docs/notes/lua/state-and-voices.md` | strata_test.lua, structure_test.lua |
| `lib/state.lua`, `lib/constants.lua` | S itself, S.constants | `docs/notes/lua/state-and-voices.md` | structure_test.lua, registries_test.lua |
| `lib/voices.lua` | `voices` | `docs/notes/lua/state-and-voices.md` | voices_test.lua |
| `lib/ui/frame.lua` | `ui_frame` | `docs/notes/lua/ui-core.md` | ui_test.lua, ui_layout_test.lua |
| `lib/engine_sync.lua` | `engine_sync` | `docs/notes/lua/engine-sync.md` | engine_sync_test.lua |
| `lib/data_files.lua` | `data_files` | `docs/notes/lua/data-files.md` | data_files_test.lua |
| `lib/side_files.lua` | `side_files` | `docs/notes/lua/data-files.md` (Side files) | side_files_test.lua |
| `lib/buffers.lua` | `buffers` | `docs/notes/lua/buffers.md` | buffers_test.lua |
| `lib/record.lua` | `record` | `docs/notes/lua/record.md` | record_test.lua |
| `lib/lfos.lua` | `lfos` | `docs/notes/lua/lfos.md` | lfos_test.lua |
| `lib/mutation.lua` | `mutation` | `docs/notes/lua/mutation.md` | mutation_test.lua |
| `lib/scenes.lua` | `scenes` | `docs/notes/lua/scenes.md` | scenes_test.lua |
| `lib/midi_in.lua` | `midi_in` | `docs/notes/lua/midi.md` | midi_in_test.lua |
| `lib/history.lua` | `history` | `docs/notes/lua/history.md` | history_test.lua |
| `lib/freeze.lua` | `freeze` | `docs/notes/lua/freeze.md` | freeze_test.lua |
| `lib/loops.lua` | `loops` | `docs/notes/lua/loops.md` | loops_test.lua |
| `lib/variation.lua` | `variation` | `docs/notes/lua/variation.md` | variation_test.lua |
| `lib/voice_mix.lua` | `voice_mix` | `docs/notes/lua/voice-mix.md` | voice_mix_test.lua |
| `lib/performance.lua` | `performance` | `docs/notes/lua/performance.md` | performance_test.lua |
| `lib/files.lua` | `files` | `docs/notes/lua/files.md` | files_test.lua |
| `lib/waveforms.lua` | `waveforms` | `docs/notes/lua/waveforms.md` | waveforms_test.lua |
| `lib/playheads.lua` | `playheads` | `docs/notes/lua/playheads.md` | playheads_test.lua |
| `lib/positions.lua` | `positions` | `docs/notes/lua/positions.md` | positions_test.lua |
| `lib/bookmarks.lua` | `bookmarks` | `docs/notes/lua/bookmarks.md` | bookmarks_test.lua |
| `lib/ui/modal.lua` | `ui_modal` | `docs/notes/lua/ui/pages-and-dispatch.md` | ui_modal_test.lua |
| `lib/quantize.lua` | `quantize` | `docs/notes/lua/quantize.md` | quantize_test.lua |
| `lib/mod_sources.lua` | `mod_sources` | `docs/notes/lua/mod-sources.md` | mod_sources_test.lua |
| `lib/macros.lua` | `macros` | `docs/notes/lua/macros.md` | macros_test.lua |
| `lib/scatter.lua` | `scatter` | `docs/notes/lua/scatter.md` | scatter_test.lua |
| `lib/morph.lua` | `morph` | `docs/notes/lua/morph.md` | morph_test.lua |
| `lib/gestures.lua` | `gestures` | `docs/notes/lua/gestures.md` | gestures_test.lua |
| `lib/input_level.lua` | `input_level` | `docs/notes/lua/input-level.md` | input_level_test.lua |
| `lib/matrix.lua` | `matrix` | `docs/notes/lua/matrix.md` | matrix_test.lua |
| `lib/notes.lua` | `notes` | `docs/notes/lua/notes.md` | notes_test.lua |
| `lib/mpe.lua` | `mpe` | `docs/notes/lua/mpe.md` | mpe_test.lua |
| `lib/params_setup.lua` | `params_setup` | `docs/notes/lua/params.md` | params_setup_test.lua |
| `lib/ui/params.lua`, `lib/ui/header.lua`, `lib/ui/flash.lua`, `lib/ui/text.lua`, `lib/ui/keys.lua`, `lib/ui/menu_watch.lua` | `ui_params`, `ui_header`, `ui_flash`, `ui_text`, `ui_keys`, `ui_menu_watch` | `docs/notes/lua/ui-core.md` | ui_test.lua, ui_header_test.lua, ui_pages_test.lua |
| `lib/ui/field_list.lua` | `ui_field_list` | `docs/notes/lua/ui-core.md` | ui_field_list_test.lua |
| `lib/ui/voice_rows.lua`, `lib/ui/cursors.lua` | `ui_voice_rows`, `ui_cursors` | `docs/notes/lua/ui-core.md` | ui_cursors_test.lua |
| `lib/ui/alt.lua` | `ui_alt` | `docs/notes/lua/ui-core.md` | ui_alt_test.lua |
| `lib/ui/detent.lua` | `ui_detent` | `docs/notes/lua/ui-core.md` | ui_detent_test.lua |
| `lib/pages/<page>.lua`: `main`, `voice`, `seq`, `fx`, `lfo`, `mod`, `buffer`, `scenes`, `setup` | `pages_<page>` (`pages_main`, ...) | `docs/notes/lua/pages/<page>.md` (`docs/notes/lua/pages/main.md`, ...) | pages_<page>_test.lua (pages_main_test.lua, ...) |
| `lib/arc/core.lua` | `arc_core` | `docs/notes/lua/arc-core.md` | arc_core_test.lua |
| `lib/arc/main.lua`, `lib/arc/voice.lua`, `lib/arc/seq.lua`, `lib/arc/fx.lua`, `lib/arc/lfo.lua`, `lib/arc/mod.lua`, `lib/arc/buffer.lua`, `lib/arc/scenes.lua` | `arc_main`, `arc_voice`, `arc_seq`, `arc_fx`, `arc_lfo`, `arc_mod`, `arc_buffer`, `arc_scenes` | `docs/notes/lua/arc-pages.md` | arc_pages_test.lua |
| `lib/grid/core.lua`, `lib/grid/faders.lua` | `grid_core`, `grid_faders` | `docs/notes/lua/grid-core.md` | grid_core_test.lua (the faders through grid_layout_256_test.lua) |
| `lib/grid/layout_<size>.lua`: `256`, `128h`, `128v`, `64` | `grid_layout_<size>` (`grid_layout_256`, ...) | `docs/notes/lua/grid/layout_<size>.md` (`docs/notes/lua/grid/layout_256.md`, ...) | grid_layout_<size>_test.lua (grid_layout_256_test.lua, ...) |
| `lib/sequencer.lua` | `sequencer` | `docs/notes/lua/sequencer.md` | sequencer_test.lua |
| `lib/Engine_Strata.sc`, `lib/engine/Strata*.sc` (`StrataUtil.sc`, `StrataVoiceDefs.sc`, `StrataGrainDefs.sc`, `StrataVoices.sc`, `StrataLifecycle.sc`, `StrataBuffers.sc`, `StrataFiles.sc`, `StrataEffects.sc`, `StrataPerformance.sc`, `StrataRings.sc`, `StrataScale.sc`, `StrataVariation.sc`, `StrataLoop.sc`, `StrataFreeze.sc`, `StrataMix.sc`, `StrataRecord.sc`, `StrataWaveform.sc`, `StrataPositions.sc`, `StrataModulation.sc`, `StrataNotes.sc`) | | `docs/notes/engine/<area>.md`, one per check area | `test/engine_check.scd` (the engine check's runner) and `test/engine_check/<area>.scd` |
| the test harness (`test/norns_stubs.lua`, `test/sync_check.lua`, ...) | | `docs/notes/test-harness.md` | stubs_test.lua, docs_test.lua |
| the page renders (`test/render_pages.lua`, `test/render_pages.py`, run on demand) | | `docs/notes/lua/ui/layout-and-renders.md` | ui_layout_test.lua (the JSON dump) |

Each screen page, grid layout and the arc's page rings have their own user page (`docs/user/pages/<page>.md`, `docs/user/grid/<size>.md`, `docs/user/arc.md`), notes file and unit test file, so the work on one page or layout edits only its own files. The release history and future ideas are in `docs/history.md`.

### Lua modules and `S`

Details, and how to register each kind of record: `docs/notes/lua/state-and-voices.md` (Modules and `S`).
- `strata.lua` holds only the entry points (`S`, one `include` per module, `init`, `redraw`, `enc`, `key`, `cleanup`, and the start steps only the script can own). Everything else is in `lib/`.
- **`S`** (`lib/state.lua`) is built fresh on every load. State more than one module uses is a field of `S` under its plain name; state one module uses stays local to it. `S.constants` is `lib/constants.lua`.
- **Includes**: only `strata.lua` calls `include`, once per module, always as `include("lib/<path>")`, never `"strata/lib/..."` (a test checks).
- **A module** is a constructor, `return function(S) local M = {} ... return M end`, ending with exactly `  return M` and `end`; its table is `S.lib.<name>`, or `S.lib.<dir>_<basename>` in a subfolder. Functions that were global stay global, in their module (`MODULE_HOMES`).
- **Registries** (`S.registry`: `pages`, `params`, `grid_layouts`, `start`, `cleanup`, `voice_params`, `scene_fields`, `source_change`, `param_filters`, `lfo_destinations`, `fx_params`, `grain_restart`, `alt_release`, `menu_close`, `invariants`, `scene_blocks`, `scene_migrations`, `pset_hooks`, `param_touch`, `lock_change`, `step_outputs`, `mod_sources`, `voice_stop`, `freeze_change`): they are read at init, never at include time (the last six are read at each use and stay open), and each `S.register_*` function checks its argument and refuses a duplicate name. Record shapes and which close at init: `docs/notes/lua/state-and-voices.md` (Modules and `S`).
- **`S.performance`** is the tier the engine runs (`lib/performance.lua` reads the engine's `performance_active.data`). Every tier-dependent spec reads it; the setting itself (`performance.data`) is SETUP's, never a param.
- Tests reach script state with `local_value(name)` and `find_upvalue(name)`: a field of `S`, then of `S.constants`, then an upvalue of a global function.

### Lua ↔ SuperCollider Communication

**IMPORTANT**: this table is the engine command interface. The tests require exactly one row per engine `addCommand`, with the same signature and argument count. Keep the row format `` | `engine.<name>(<args>)` | `"<sig>"` | purpose | `` and update the table in the same commit as the engine. No `engine.<name>(` mentioned in the maintained docs may name a command the engine no longer has. A row gives each argument's range and values; what the command does is in the area notes under docs/notes/engine/.

| Lua Command | SC Signature | Purpose |
|-------------|--------------|---------|
| `engine.voiceOn(voice, freq, amp, pan, grainSize, grainDensity, pitchShift)` | `"iffffff"` | Start a voice (resets `bend` to 1). Never stacks: synths still running or releasing are re-gated |
| `engine.voiceOff(voice)` | `"i"` | Stop a voice (release envelope) |
| `engine.retrigger(voice, velocity)` | `"if"` | Accent a running voice at velocity 0-1 (Karplus re-plucks; one grain in triggered mode). Creates no nodes |
| `engine.setVoiceParam(voice, param, value)` | `"isf"` | Set a synthesis param, or `bend` (MIDI pitchbend ratio) |
| `engine.setGrainParam(voice, param, value)` | `"isf"` | Set a grain param (`envShape` index, `grainMode` 0 continuous / 1 triggered, `bufPos`, `freeze` 0/1, `freezeMode` 0 hold / 1 spectral, `t_scanReset` not stored, `scrubRate` and `scanHold` transient, ...) |
| `engine.setMasterDrift(amount)` | `"f"` | Global tape drift |
| `engine.setReverb(mix, size, damp)` | `"fff"` | Reverb mix 0-1, size, damping. `FreeVerb2` on standard, the FDN on high. Kept while bypassed |
| `engine.setFilter(freq, res, type, mix)` | `"ffif"` | Master filter, on all three of its instances (dry, delay send, reverb send): 20-20000 Hz, res 0-1, type 0 LP / 1 HP / 2 BP, mix 0 = bypass |
| `engine.setDelay(time, feedback, mix)` | `"fff"` | Master delay: 0.01-2 s, feedback 0-0.95, mix 0-1 (0 = dry, the node keeps running). Kept while bypassed |
| `engine.setBypass(effect, bypassed)` | `"ii"` | Effect 0 delay / 1 reverb (others ignored), bypassed 0 or 1: frees the node after its fade and re-creates it in its place when lifted. Only this frees an effect |
| `engine.setModSource(voice, slot, sourceVoice)` | `"iii"` | Crossmod source for slot 1-3 (-1 = none → `silentBus`, 0-6 = voice). The three crossmod commands ignore any other slot |
| `engine.setModAmpAmt(voice, slot, amount)` | `"iif"` | Crossmod amplitude depth (-2 to 2) |
| `engine.setModFreqAmt(voice, slot, amount)` | `"iif"` | Crossmod frequency depth (-2 to 2) |
| `engine.setModSpeed(voice, speed)` | `"if"` | Mod signal LFO speed (0.1-50), kept per voice |
| `engine.setGrainSource(voice, source)` | `"ii"` | 0 = synth, 1-8 = buffer slot, 9 = input. Replaces a running voice's grain synth (never stacks), records a stopped voice's choice; same source = no-op |
| `engine.loadBuffer(slot, path, start)` | `"isf"` | Read a file into slot 0-7 from `start` seconds into it (at the file's rate; 0 = the beginning), at most `bufferSeconds` at the server rate; voices reading the slot fade first. A failure is reported on `bufferLoadFailed`. `docs/notes/engine/buffers.md` |
| `engine.recordBuffer(slot, seconds, level, feedback, source, threshold, loop, delay, sent)` | `"ifffififf"` | Record `source` (0 input, 1 pre-master, 2 post-master, 3-9 voice 1-7; others input) × `level` into slot 0-7 for `seconds` (at most `bufferSeconds`): each frame keeps the old audio × `feedback` (0 with `loop` 0 is a replace take), `loop` 0/1, `threshold` linear (0 = none), starting `delay` s after `sent` (`util.time() % 1000`). States on `recordState`. `docs/notes/engine/record.md` |
| `engine.clearBuffer(slot)` | `"i"` | Zero slot 0-7 after its voices fade (cancels a recording) |
| `engine.stopRecord(slot)` | `"i"` | End slot 0-7's recording now, with its 5 ms fade, and keep what was captured; an armed one that has not started is canceled. No-op without one. `docs/notes/engine/record.md` |
| `engine.saveBuffer(slot, path, start, length)` | `"isff"` | Write `[start, start + length)` of the slot's valid region (fractions; 0, 1 = all of it) as a stereo 16-bit WAV. The outcome is reported on `bufferSaveResult`. `docs/notes/engine/files.md` |
| `engine.setScale(root, mask)` | `"ii"` | The scale every quantized grain lands on: root 0-11 (0 = C), mask 1-4095, a 12-bit pitch-class set from the root (4095 = chromatic, the default). Other values are ignored |
| `engine.setFastLfo(lfo, voice, destination, shape, rate, depth, offset)` | `"iiiifff"` | Engine LFO 0-5 on voice 0-6's fast destination 0-4 (pitch, position, size, cutoff, amp): shape 0-7 (sine, tri, square, up, down, s&h, smooth, drunk), rate 0.003-50 Hz, depth 0-1, offset -2..2 (half ranges). Never more than one node per LFO |
| `engine.stopFastLfo(lfo)` | `"i"` | Release LFO 0-5's node (20 ms) and zero its channel. No-op without one |
| `engine.syncFastLfo(lfo, phase)` | `"if"` | Set LFO 0-5's phase (0-1) now. No-op without a node |
| `engine.setScatter(depth, rate, destinations, voices)` | `"ffii"` | Scatter: depth 0-1 (0 releases the node), rate 0.01-1 Hz, destinations a 5-bit mask (bit d = destination d), voices a 7-bit mask (bit v = voice v) |
| `engine.setFastOffset(voice, noteSlot, destination, offset)` | `"iiif"` | Set the Lua-computed offset (-2..2 half ranges, clamped) on voice 0-6's note slot (0 in 3.4; 0..`fastModNoteSlots` - 1) and fast destination 0-4, lagged 50 ms. Creates no node |
| `engine.noteOn(voice, slot, note, freq, rate, velocity)` | `"iiffff"` | Start voice 0-6's note slot 0-7 (0 its own note, 1-7 extra): note 0-127, freq 8-20000 Hz, rate 0.25-4, velocity 0-1 |
| `engine.noteOff(voice, slot, cut)` | `"iii"` | End voice 0-6's slot 0-7: cut 0 releases, 1 cuts (50 ms) |
| `engine.noteExpression(voice, slot, bend, amp, position, size, main)` | `"iifffff"` | Voice 0-6's slot 0-7 expression: bend ratio 0.0625-16, amp 0-2, position, size and main -1..1 half ranges. Creates no node |
| `engine.setNotePool(size)` | `"i"` | The extra notes all voices share, 0-16 (`notePoolMax`) |

**3.4's five fast-modulation and 3.5's four note commands** (the last nine rows; `docs/notes/engine/modulation.md`, `docs/notes/engine/notes.md`): each ignores an out-of-range index or a non-finite continuous argument with one console line, and clips its continuous arguments to the ranges above. Until 3.5's note lifecycle the note commands are stubs: they record and create no node.

**Polls** (engine → Lua). matron's polls carry one float, so each message packs its fields into one number, and Lua matches each report to the command it names (each side counts a slot's loads, saves and recordings from 1): `bufferState`, `recordState` and `takeWriteFailed` act only for the newest, `bufferLoadFailed` undoes exactly the load it names, and `bufferSaveResult` flashes only for the newest save. The formulas, what each side does with them and the rules are in `docs/notes/engine/buffers.md` (Polls, The polls' encodings), `docs/notes/engine/record.md`, `docs/notes/lua/buffers.md` and `docs/notes/lua/record.md`:
- `bufferState`: one slot every 0.25 s in turn, then the slots' length (as slot 8 with load 0), and every change at once, as `(load_number * 9 + slot_index) * 1000 + seconds` (the load number modulo 7).
- `bufferLoadFailed`: once per failed load, as `(load_number * 2 + emptied) * 8 + slot_index`.
- `bufferSaveResult`: once per save whose write ends, as `(save_number * 2 + failed) * 8 + slot_index`.
- `recordState`: once per change of a recording's state, as `((record_number * 4) + state) * 8 + slot_index` (0 armed, 1 recording, 2 ended and kept, 3 canceled).
- `takeWriteFailed`: once per kept take whose scratch file could not be written, as `record_number * 8 + slot_index`.

**Index conversion**: voices are 0-indexed in SC and 1-indexed in Lua, so always pass `voice_idx - 1`. Mod sources go through `engine_mod_source()` (Lua 0 = none / 1-7 → SC -1 / 0-6).

**The `voices` table is the only source of values.** The engine holds no per-voice defaults. A start (`S.lib.engine_sync.start_voice`, from `toggle_voice` or a pattern step) sends `setGrainSource` and every grain value before `engine.voiceOn`, and the synth and crossmod values after it. Param actions reach the engine only while a voice is active. The `v<i>_source` action is the exception: it also reaches stopped voices.

### Invariants that are easy to break

One or two lines each: the rule, then the notes file whose "Must not break" list holds the detail, the reasons and the exceptions. Read that file before changing the code a rule names.

The engine's (under docs/notes/engine/):
- **A voice's own note never creates a node** on a step or a MIDI note (`retrigger`); an extra note creates exactly one synth in its slot, through `S.lib.notes` alone. Velocity only scales the accent envelope's `levelScale` in every voice and grain SynthDef and in `\strataVoiceMix` (Karplus's pluck impulse is the one allowance). `docs/notes/engine/voices.md`, `docs/notes/lua/notes.md`
- **Replace, never stack**: a source switch replaces the grain synth; fading synths are cut with `cutSynth`, never a second `release`; new grain synths are placed with `startPlacedGrainSynth`. `docs/notes/engine/lifecycle.md`
- **`openedGate(gate)`** wraps every ASR gate; never `gate.max(...)`. `docs/notes/engine/lifecycle.md`
- **Silent bus**: unrouted mod slots read `silentBus`, never control bus 0. `docs/notes/engine/voices.md`
- **Limiter before the tanh saturator** in `\strataMaster`, never after it. `docs/notes/engine/effects.md`
- **One grain path**: every grain synth is a `GrainBuf` pair built by `grainBody`, pitch is the grain rate, and it writes only its source kind's path (`voicePathBus`); no grain SynthDef has a delay line (`PitchShift`, `DelayC`), filter, send, mirror or voice-level amp, and its only gain is the note's: `noteAmp` and the note's accent. `docs/notes/engine/grains.md`
- **Buffer and input sources have no voice synth**: their grain synth writes the voice's other path, which the stage mirrors to `granBuses[i]` so crossmod keeps working; the synth path never mirrors, and the synth-source grain synth keeps `pan` and `rateLevel` at 0. `docs/notes/engine/grains.md`, `docs/notes/engine/mix.md`
- **One persistent stage per voice** (`\strataVoiceMix`, `effectKeys`, never re-gated), at the tail of its mix group, just before the voice's mod synth; in `processGroup`, synth-source grain synths sit at the head, buffer and input grain synths at the head of their voice's mix group. The level comes after the voice filter, on the other path only; inputs and filter outputs go through `zeroBadValues`. `docs/notes/engine/mix.md`
- **Ring writers** run at the tail of `voiceGroup`, are persistent `effectKeys` and zero bad input; a ring grain reads behind the write head and never past the ring. `docs/notes/engine/rings.md`
- **The ring head is read sample by sample**: `ringGrainReader` starts every ring grain the lookback and one block behind the write head wherever its trigger falls in a block, so it never holds the head for a block without adding the sample's offset. `docs/notes/engine/rings.md`
- **`ringReaders`** maps every `\strataGrainRing` to its voice until it frees; only its writer writes a voice ring or the input ring; an input freeze's copy fades the copy ring's readers first and runs only if `ringChanges[voice]` is unchanged. `docs/notes/engine/rings.md`
- **Freeze** changes a synth voice's ring writer only with `run` or `Synth.replace`; an input freeze uses only the voice's copy ring (`copyRingFor`, `copyWriterKeys`); spectral exists on high only; a source switch unfreezes first; an unfreeze's re-point and `freeze` 0 go in one bundle; ring reads come from `grainReadPairs`. `docs/notes/engine/freeze.md`
- **No `LocalBuf` in any engine SynthDef** (a structure test enforces it). `docs/notes/engine/freeze.md`
- **Every SoundFile `readData` reads into a fresh array** (`freshReadArray`; a structure test enforces it). `docs/notes/engine/files.md`
- **No per-sample sclang loop in engine code**: build sample arrays with C primitives (a structure test enforces it in `StrataFiles.sc`). `docs/notes/engine/files.md`
- **No List that grows without bound while sclang allocates heavily** (an OSC responder, a polling loop, a long routine): make it with room for all it will hold (`List.new(n)`) or bound it. `docs/notes/engine/files.md`
- **Buffer memory**: slots of `bufferSeconds` (16 s standard; high steps its setting down through `highMemoryBytes` to leave 1 GB), voice rings and copy rings of 4 s and the input ring; never allocate longer ones; bufnums never change. `docs/notes/engine/memory.md`, `docs/notes/engine/performance.md`
- **Real-time memory**: norns' pool is 8192 KB. Every `GrainBuf` uses `maxGrains` (128); never size a delay line or table from a control; a voice holds at most its live synths, one fading and one cutting set; the check requires 3 MB free on standard and 3.5 MB on high at the worst cases, every grain synth under 88 KB and each mix stage under 42 KB. A new delay line, table or node per voice needs the budget re-measured. `docs/notes/engine/memory.md`
- **Fast modulation**: every channel of `fastModBus` comes from `fastModChannel`; the buses hold offsets only and Lua owns every base value; the cutoff and amp offsets belong to the per-voice stage (`voiceMixMod`); at most one node per engine LFO at every moment, a releasing one included, and one scatter node; a channel is zeroed when its last writer ends. `docs/notes/engine/modulation.md`
- **The step gate and mute are the stage's** (`voiceGate`, on the whole output but the mirror): velocity never reaches the gate's envelope; `seqGate`, `gateSeconds`, `gateRelease` and `voiceMute` are kept in `grainControls[voice]` (Lua sends `gateSeconds` only when it changes and relies on it). `docs/notes/engine/modulation.md`
- **`slotChanges[i]`** guards late replies and the fade wait (a clear or load sent later always wins); load and save reports name their number. `docs/notes/engine/buffers.md`
- **One record synth per slot, only in the tap group** (`areaState[\record][\tapGroup]`, after the master): a new recording, load or clear frees the old one at once, even in its stop fade. A playable recording never shrinks its slot and zeroes it only through `afterSlotFade`; every delayed step of a recording runs only if `slotChanges` is unchanged. `docs/notes/engine/record.md`
- **The head guard** (`slotHeadGuard`) passes a grain's start through when the head bus reads -1, moves a start the head would meet during the grain's life to the zone's edge (never past D), and keeps it in `slotGrainPos`'s valid range. `docs/notes/engine/record.md`
- **Chunk loops in a routine** wait through `yieldToCommands`, never a plain `wait`. `docs/notes/engine/files.md`
- **Fade before zeroing**: never zero a slot directly; go through `afterSlotFade`, and fading `\strataGrainBuf`s only ever get `bufFrames 0`. `docs/notes/engine/buffers.md`
- **Messages to synths that can end on their own** go through `sendToSynth`, never `synth.set`/`release`/`free`/`moveBefore`; the effects chain's `effectKeys` get plain sends. `docs/notes/engine/lifecycle.md`
- **Bypass is explicit**: only `setBypass` frees the delay or reverb and re-creates it in its place; a mix at 0 only silences; the master filters are never freed. `docs/notes/engine/effects.md`
- **Sends reproduce 3.0's chain**: every mix reader lags 0.05 s, the bus and the nodes' mix controls move in one bundle, and a stage gets its send and mix buses through `stageControls` (`docs/notes/engine/mix.md`). `docs/notes/engine/effects.md`
- **NaN guards**: the three `\strataFilter`s and `\strataMod` (input and output) replace bad values with `zeroBadValues`. `docs/notes/engine/effects.md`, `docs/notes/engine/voices.md`
- **File writes** go to a `.part` file renamed into place, never the final path; `deleteStaleParts` deletes only old `.part` and temporary float files; a peaks write, a save or a scratch take renames through `renameIntoPlace` (the waveform area's mover, with its own fallback), never a `unixCmd` or `systemCmd` of its own. `docs/notes/engine/files.md`, `docs/notes/engine/waveform.md`
- **The peaks file is in place before the length is reported**: a load's `bufferChanged` runs as `writeSlotPeaks`' action, after the rename; a failed write still reports the length. `docs/notes/engine/waveform.md`
- **The peak scan allocates nothing per sample**: bin-aligned chunks and `Signal`'s `peak`, never `maxItem` or `minItem` (a structure test enforces it). `docs/notes/engine/waveform.md`
- **`\strataFilter`**: never compare a UGen with `==`; use `BinaryOpUGen('==', ...)`. `docs/notes/engine/effects.md`
- **The filter's highpass and cutoff**: `multimodeFilter` runs `RLPF` and `BPF` only, the highpass is the input less both (never an `RHPF`), and a cutoff rises at most `cutoffRiseRate` through `riseLimitedCutoff`. `docs/notes/engine/effects.md`
- **No slot grain reads past the valid region**, forward or reverse, whatever the loop: the loop is cut to the legal starts with audio-rate `max` and `min` (never a control-rate `Clip`), never shortens a grain, and the engine never trusts Lua's start and length pairing. `docs/notes/engine/loops.md`
- **Grain draws latch per grain**: every variation draw is a `TRand`/`TIRand` on the grain trigger feeding a `GrainBuf` input; size jitter never makes a grain longer than 0.5 s; quantize comes before bend and crossmod; `scaleBuffer`'s bufnum never changes. `docs/notes/engine/variation.md`
- **Transient scan state**: `scrubRate`, `scanHold` and `t_scanReset` are never params, scene or PSET fields (the one exception to the `voices` table holding every value); `t_scanReset` is never stored; every voice sync sends the other two as 0; every grain start restarts the scan. `docs/notes/engine/positions.md`, `docs/notes/lua/positions.md`
- **The engine runs the tier Lua reads**: `parseActivePerformance` stays identical to `S.lib.performance.parse_active_text`, the step-down arithmetic matches what the rings area allocates, and the poll's slot length only ever lowers Lua's `S.performance.buffer_seconds`. `docs/notes/engine/performance.md`, `docs/notes/lua/performance.md`

The Lua side's, across modules:
- **Param → engine**: a control param's action calls `send_param_to_engine(id, value)` with an `S.engine_senders[id]` entry, never `engine.*`; a command carrying several params reads the others with `engine_param_value(id)`; LFOs never `params:set` their destination. `docs/notes/lua/engine-sync.md`, `docs/notes/lua/lfos.md`
- **Scenes**: a new captured field needs `validate_scene` coverage and a migration default; discrete keys switch at the end of a transition, never crossfade; a recall sends one full sync per running voice whose source changed. `docs/notes/lua/scenes.md`
- **Data files** (`scenes.data`, `buffers.data`, `macros.data`, `matrix.data`, `gestures.data`, `grids.data`, `notes.data`) are written only through `S.lib.data_files.write` and read only through `S.lib.data_files.read`, never `tab.save` or `tab.load`; a backup never replaces an earlier one. `docs/notes/lua/data-files.md`, `docs/notes/lua/scenes.md`, `docs/notes/lua/buffers.md`
- **Source tests**: `voice_uses_synth(i)` / `voice_uses_buffer(i)`, never `not voice_uses_synth` (that includes input). `docs/notes/lua/state-and-voices.md`
- **Grid, arc and MIDI handlers live on the vport only**, never on the raw device passed to `grid.add`. `docs/notes/lua/grid-core.md`, `docs/notes/lua/arc-core.md`, `docs/notes/lua/midi.md`
- **Arc rings** sweep their range in 1024 ticks through `arc_sweep_param` and draw through `arc_ring_fill` from `param_fraction`, never a bare `segment` or a hardcoded range (the exceptions are SEQ's step editor and MOD's targets view); whole-step rings carry ticks through `arc_whole_steps`; Strata follows one arc. `docs/notes/lua/arc-core.md`, `docs/notes/lua/arc-pages.md`
- **Lock** is the user's name (`[L]`, the hints, `toggle_lock`) for the state `S.frozen`; "freeze" is 3.2's audio freeze, never said with the lock in user docs unless contrasting, nor named with it in code; randomize, drift, mutation and scatter leave a locked voice alone, and it can still be edited. `docs/notes/lua/freeze.md`, `docs/notes/lua/mutation.md`
- **Randomize undo**: every page randomize (ALT+K2) goes through `S.lib.mutation.randomize(spec)`, and every param a spec draws calls `note_param_edit` from its action; there is one undo, `S.undo`, undone only where it was made (`undo_for`); a binary draw goes through `set_binary_param`. `docs/notes/lua/mutation.md`
- **LFOs**: one 48 Hz clock (`S.lfo_clock`) steps the six in index order; one on a fast destination runs in the engine (`setFastLfo`, `stopFastLfo`, `syncFastLfo`), every other in Lua through `S.lib.lfos.mark_due` (at most 12 sends a step, each inside `deferrable`); a modulation input reads lower-numbered LFOs only. `docs/notes/lua/lfos.md`
- **Selected voice**: after init, `S.selected_voice` changes only through `S.lib.ui_keys.select_voice_by`. `docs/notes/lua/midi.md`
- **Filter restore mix**: `S.fx_last_mix.filter` changes only in `lib/params_setup.lua`, never in the FX page; the delay and reverb have none. `docs/notes/lua/pages/fx.md`
- **Registered per-voice params** (freeze, variation, loops, history, voice mix, seq) default to 3.1's sound and never reach MAIN's randomize, mutations or the 256 fader pages (`fader = false`), but for their own section's page randomize; registered LFO destinations follow every built-in one. `docs/notes/lua/params.md`
- **Mute and solo**: a mute silences in the mix stage (`voiceMute`, sent as `S.lib.voice_mix.silenced(voice)`, never as a stored value) and never stops a voice; scenes store mutes and never solos. `docs/notes/lua/voice-mix.md`
- **Loop pairs**: scenes set `loop_length` before `loop_start` (sorted key order), so the length's filter stands down during a recall or transition, the start's action cuts a length that does not fit, and a loaded pair goes through `normalize_scene`. `docs/notes/lua/loops.md`, `docs/notes/lua/scenes.md`
- **Scale quantize**: one `freq` filter snaps a per-voice shadow note that only a turn moves (`S.lib.ui_detent.as_turn`); every other set snaps its own value; `scaleNote` is resent whenever it moves; a voice's `quantize` loads ahead of its `freq` (`add_first`). `docs/notes/lua/variation.md`
- **Recordings (Lua)**: the record params are PSET-only, never scene fields; only a slot's newest recording's reports act; every path that ends a recording cancels its timer through `S.lib.record.cancel_timer(slot)`; what a slot holds is `S.lib.buffers.status(slot)` and `is_free(slot)`. `docs/notes/lua/record.md`, `docs/notes/lua/buffers.md`, `docs/notes/lua/files.md`
- **Peaks and playheads**: a peaks file is read only in `lib/waveforms.lua`'s clock loop; pages and grids read the waveform, heads and bookmarks only through `S.lib.waveforms`, `S.lib.playheads` and `S.lib.positions`, and send no engine command for them. `docs/notes/lua/waveforms.md`, `docs/notes/lua/playheads.md`, `docs/notes/lua/pages/buffer.md`
- **The playhead restarts where the engine's scan does** (a `voiceOn`, a source switch through `S.register_grain_restart`, a jump); call `S.lib.playheads.advance(v)` before changing the hold or the glide's rate. `docs/notes/lua/playheads.md`
- **Jumps and recalls** enter only through `S.lib.positions.jump` and `recall_bookmark`; the scan hold, the glide and the last recalled bookmark are never params, scenes or PSETs. `docs/notes/lua/positions.md`
- **Bookmarks, 3.4's interface**: `S.lib.bookmarks.recall(v, n)` and `is_set(v, n)` keep their names and behavior and never create a node. `docs/notes/lua/bookmarks.md`
- **Macros**: a macro never targets a macro or the morph (`S.lib.macros.target_ids()` is the only list of targets); scenes, a transition and morph set a macro silently (`set_silently`); every apply's fan-out is one `deferrable`, from `S.macro_clock`; an LFO on a macro moves engine values, never a param. `docs/notes/lua/macros.md`
- **The matrix adds offsets and never sets a destination param**: a Lua destination's routings sum into `set_extra_offset("matrix", id, sum)`; a fast one reaches the engine only as `send_engine_value("matrix fast <voice> <destination>", sum)`, never `setGrainParam` or a bare `setFastOffset`; every send goes through `S.lib.lfos.mark_due`. `docs/notes/lua/matrix.md`
- **Morph writes params and never recalls**: it never calls `recall_scene` or `recall_scene_instant`, starts a transition or clears the undo; values go through `S.lib.scenes.set_value` and `apply_entries(entries, {only = "discrete"})`, inside `deferrable`, from `S.morph_clock`; a later recall or fade wins. `docs/notes/lua/morph.md`
- **The sequencer plays only through step outputs** (`S.register_step_output`): each hit goes to every output, each call in a coroutine of its own (one that raises or yields is skipped), and an output's `play` never yields. The `voices` output is the exception: its error stops the patterns and is raised again. Steps never create nodes: a stopped voice is started with `start_voice` at a step's first hit, a running one gets `retrigger`. `docs/notes/lua/sequencer.md`
- **Step locks and notes are base overrides** (`S.lib.engine_sync.set_base_override`), never `params:set`; they end at the voice's next step without them, a stop, `replace_pattern` or a shorter length. `docs/notes/lua/sequencer.md`
- **Strata follows the transport and never leads it**: `clock.transport` start and stop move the patterns only while `seq_follow_transport` is on; nothing calls the clock's own start or stop; a clock tests the beat its `clock.sync` returned, never the live beat. `docs/notes/lua/sequencer.md`
- **Notes** are played, released and expressed only through `S.lib.notes`, which alone calls `noteOn`, `noteOff`, `noteExpression` and `setNotePool`; its flush sends at most 16 `noteExpression` a step, counted (`count_sends`), never deferred. `docs/notes/lua/notes.md`

## Working in parallel

Several pull requests are built at once, often by agents: a feature lives in files that only its work edits, apart from one-line registrations. How a session runs packages through agents (the controller, workers and reviewers, scratch folders, the ledger, briefs, reports, landing, a release's steps and cleanup) is in `docs/workflow.md`. The rules every change follows:
- **Superpowers skills, invoked, not imitated**: each session invokes the skill for its step with the Skill tool, as `docs/workflow.md` (Skills) lists them: `superpowers:brainstorming` for a new design, `superpowers:writing-plans`, `superpowers:using-git-worktrees`, `superpowers:subagent-driven-development` (the controller, at a plan's start and on every resume), `superpowers:test-driven-development` (every worker changing code or tests), `superpowers:requesting-code-review` (a review outside a plan's task loop) and `superpowers:finishing-a-development-branch` (pull request only). Following a skill from memory does not count. Where a skill differs from `docs/workflow.md` or this file, those win (parallel packages, rebase-only merges).
- **Rebase, never merge main in**: `git fetch -q origin && git rebase origin/main`, then `git push --force-with-lease`; never `git merge origin/main`, never `gh pr update-branch` without `--rebase`. Pull requests merge with rebase (`gh pr merge --rebase`), so `main` stays linear. A plan's reviewed packages land in batches, one pull request per batch, so a worker rebases only when the controller asks (`docs/workflow.md`, Landing in batches).
- **One worktree per pull request**, branched from an up-to-date `main`; never share a checkout between two pieces of work. Engine checks in different worktrees run on different `$STRATA_SC_PORT` ports.
- **Own scratch folder and worktree, nothing else**: never write to, rename or delete another worker's folder, worktree, logs or containers. Remove only a worktree you created, with `git worktree remove`; leftovers are the controller's or the maintainer's to clean up. The controller's ledger is `.superpowers/sdd/<plan>/progress.md` in the main checkout, never in a worktree.
- **Edit only the files your package owns** (a release's design lists them; for 3.1, §9 of `docs/design/3.1-design.md`), plus registration lines and the package's own notes file, unit test file and `docs/user/` page. Need a change in a file another package owns? Ask for it, or make it a separate pull request.
- **Registering** is a few lines in the owning module, and the pointers name any other file: a page (`docs/notes/lua/ui/pages-and-dispatch.md`, Registering a page), a param group, per-voice params and the other shared spots (`docs/notes/lua/params.md`, Registering params), a start or cleanup step (`docs/notes/lua/state-and-voices.md`), a grid layout (`docs/notes/lua/grid-core.md`), an engine area (`docs/notes/engine/structure.md`, Areas). `init`, `cleanup()` and `lib/Engine_Strata.sc` are never edited.
- **On a conflict in a registration line** (an include, a `UI_PAGES` entry, a `START_ORDER` or `CLEANUP_ORDER` entry, a `register_params` call, a module table row in this file): keep both lines, in the order the sequence needs, and rerun the checks. Two `START_ORDER` or `CLEANUP_ORDER` entries on the same number: give the later one a free number.
- **Shared files** (CHANGELOG.md, `docs/status.md`, this file, README.md, `ROADMAP.md`, `docs/history.md`): edit them only where your package needs to. A feature pull request never edits CHANGELOG.md.
- **Changelog**: every pull request adds a changelog fragment `changes/<branch-name>.md`; see `changes/README.md`. The release pull request merges the fragments into CHANGELOG.md.

## Development & Testing

How to run each check, what it needs and how CI runs them: `docs/checks.md`. How the harness works: `docs/notes/test-harness.md`.

**On norns:** copy the project to `~/dust/code/`, then restart norns from its menu (SYSTEM > RESTART): every engine change needs it. maiden's `;restart` restarts only matron, norns' Lua side, so it never picks up an engine change.

**Off-device checks** (run from the repo root before committing; CI runs all three):
- `lua test/run.lua` and `luajit test/run.lua`: the behavior tests against norns stubs, one file per module under test/unit/ (discovered automatically). `lua test/run.lua <filter>` runs the unit files whose name contains `<filter>` (`lua test/run.lua lfos`; `pages` runs every page's file). Run your module's file while you work and the whole suite before pushing. The run includes the sync check, the docs checks over the maintained docs (paths, commands, links, headings, US spelling), the changelog fragment check and the module safety nets (`docs/notes/test-harness/run-and-helpers.md`).
- The engine stub rejects any `engine.*` call whose name, argument count, types or ranges do not match the engine source, or whose `setVoiceParam`/`setGrainParam` name is not a SynthDef control (`docs/notes/test-harness/engine-stub-and-sync.md`).
- `lua test/sync_check.lua`: every `engine.<name>(...)` call has a matching `addCommand`, and every command is used but those in its `PENDING_COMMANDS` (the commands the engine has before the script calls them; none today). Call engine commands only as `engine.<name>(...)`: any other use of `engine` (`engine[name](...)`, `local f = engine.voiceOn`, `local e = engine`) fails the check.
- `test/run_engine_check.sh [path/to/norns]`: compiles the engine against norns `sc/core` (default `~/src/norns`, or `$NORNS_DIR`) and runs the area files `test/engine_check/<area>.scd` on a silent local scsynth. `STRATA_ENGINE_CHECK_AREAS=memory` runs only the areas it names: work on an area with its own run, and run all areas before pushing (CI's shards, each in a fresh sclang: about 17 minutes of areas, 18 in all). Each run boots scsynth on `$STRATA_SC_PORT` (default 57110; avoid 57120 and the few above it): runs on the same port collide. A new area adds its file, its name in `areaOrder` and its notes file. The soak (`STRATA_ENGINE_CHECK_AREAS=soak`) runs only when named.
- `test/run_engine_check_313.sh [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]`: the engine check on SuperCollider 3.13 (norns' and CI's version) in Docker. A full run is CI's shards, read from `.github/workflows/test.yml`, each in a container of its own; `-1` runs it in one sclang, `-l` prints the shards and `-c` classifies a log folder again (`docs/notes/test-harness/engine-check-runner.md`).
- Page renders, on demand: `lua test/render_pages.lua <dir>` then `python3 test/render_pages.py <dir> --font ~/src/norns/resources/norns.ttf` draw every page state as a PNG. Look at them after a layout change (`docs/notes/lua/ui/layout-and-renders.md`).
- Add a test to the unit file of the module you change, for every behavior change. Tests reach script state through `local_value()`/`find_upvalue()` (fields of `S`, then `S.constants`, then upvalues), so a name the tests use must stay a field of `S` or `S.constants` under that name.
- The stubs mirror the real norns libraries (`~/src/norns/lua`): check behavior there before changing them (`docs/notes/test-harness/stubs.md`, `docs/notes/test-harness/clock.md`). `param.t` holds numeric type codes (`params.tOPTION`, ...): never compare it with a string.
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file: norns compiles every `.sc` under `~/dust`.

**Common norns pitfalls:**
- `UI.List` has no `set_items()`: recreate the list. `UI.List.new(x, y, index, items)` needs every argument.
- `clock.sleep()` works only inside `clock.run(...)`. Never call it in `init()`.
- Param IDs must be unique, and norns has built-ins such as `reverb`. Use prefixed ids (`strata_fx`, ...).
- A group's size `n` must equal the number of params that follow it. Groups cannot nest.

## Code Style Guidelines

**Named constants, never magic numbers.** They live in `lib/constants.lua` (`S.constants`, aliased as locals at the top of each module that uses them): `NUM_VOICES` (7), `NUM_SCENES` (16), `PATTERN_LENGTH` (16), `SCENE_DATA_VERSION` (6), `NUM_MOD_SLOTS` (3), `NUM_UI_PAGES` (9, `#UI_PAGES`), `MAX_STEP_LEVEL` (15), `NUM_BUFFERS` (8), `STANDARD_BUFFER_SECONDS` (16), `STANDARD_PERFORMANCE`, `BUFFER_DATA_VERSION` (2), `PSET_FORMAT` (2, the hidden `strata_pset_format` every PSET holds), `NUM_LFOS` (6, the engine's `numFastLfos`), `NUM_BOOKMARKS` (4), `WAVEFORM_POINTS` (64, the engine's `waveformPoints`), `RECORD_SOURCES`, `RECORD_SYNC`, `FILES`, `WAVEFORMS`, `PLAYHEADS`, `SCRUB` and `NORNS_SAMPLE_RATE` (48000), and 3.4's `NUM_MACROS` (16), `MACRO_BANK_SIZE` (4), `MACRO_TARGETS` (8), `MATRIX_SLOTS` (16), `NUM_GESTURES` (4), `SCENE_BANK_SIZE` (8), `SCENE_NAME_MAX` (12), `GRID_HOLD.step_edit_seconds` (0.3) and `ENGINE_BUDGET` (`messages_per_window` 150, `window_seconds` 0.1: the deferrable sends' budget, `lib/engine_sync.lua`). The engine mirrors them as `numVoices`, `numBuffers`, `standardBufferSeconds` and `numModSlots`. 3.4's fast modulation adds `NUM_FAST_DESTINATIONS` (5) and `FAST_MOD_NOTE_SLOTS` (1), mirrored by the engine's `numFastDestinations` and `fastModNoteSlots` (a docs test compares them). 3.5 adds `NOTE_SLOTS` (8) and `NOTE_POOL` (`max` 16, the tiers' defaults `standard` 4 and `high` 8), mirrored by `noteSlots` and `notePoolMax`. The slot length is a tier value, not a constant: read `S.performance.buffer_seconds`. Never hardcode 7, 8 or 16 in voice, scene, pattern or buffer code (bare numbers in grid code are coordinates and LED levels).

**Lua's 200-local limit applies to each function, checked by a test**: every file's main chunk and every module constructor keeps at least 30 locals free; group a feature's constants in one table (`LFO_PAGE`, ...) and split a module that runs short (`docs/notes/lua/state-and-voices.md`).

**Descriptive names**: `selected_voice`, not `sv`; `master_density`, not `md`.

**Bounds-check every index** (voice 1..`NUM_VOICES`, scene, step, slot, grid coordinates) before indexing. **Clean up** every metro, clock, poll and device handler through `S.register_cleanup` at its place in `S.constants.CLEANUP_ORDER`, never code in `cleanup()`; cancel a clock before starting its replacement (`docs/notes/lua/state-and-voices.md`).

**No unguarded recursive deletes**, in code or in your shell: tests delete only through `h.remove_tree`; a command runs `rm -rf -- "${dir:?}"` on a quoted, spelled-out absolute path, and a worktree goes with `git worktree remove`, never `rm` (`docs/notes/test-harness/run-and-helpers.md`).

**Keep docs current in the same change**: the `docs/user/` page for the area (user-facing behavior; README.md only for the overview, quick start and index), the module's notes file (implementation details, and its "Must not break" list), this file (rules, the command table, the module table) and `docs/status.md`.

### CRITICAL: keep Lua and the engine in sync

- A new or changed `addCommand` needs: matching `engine.*` calls (same count and types; SC type codes i/f/s), the table row above, and the engine stub picks it up from the SC source.
- A new SynthDef argument the user controls needs: the `voices` table default, the voice's `param_order`, `add_voice_params()`, `get_param_spec()`, a sender in `S.engine_senders`, and the exact case-sensitive name. Grain params go through `setGrainParam` and `GRAIN_PARAM_IDS`.
- Lua defaults are what the engine plays (`S.lib.engine_sync.start_voice` sends them at every start). SynthDef defaults for the filter and delay must equal the Lua param defaults, because the script never bangs its params.
- New voice-level controls that a buffer or input grain synth also needs belong in `voiceControls` / `grainControls` and `controlNameSets` (see Audio Sources in `docs/notes/engine/grains.md`).

### IMPORTANT: update the UI with every feature (128×64 screen)

Details: the UI core's notes (`docs/notes/lua/ui-core.md`, an index of docs/notes/lua/ui/) and each page's `docs/notes/lua/pages/<page>.md`.
- **Pages**: one record per page file at `S.registry.pages[UI_PAGES.index.<PAGE>]`; only `lib/arc/<page>.lua` sets its four arc fields. Find a page by index, never by its title; change pages only through `S.lib.ui_keys.set_ui_page`, never by setting `S.ui_page`; change a page's draw or hints, never `redraw()` (whose one other dispatch is the modal owner, `S.lib.ui_modal.push`). `docs/notes/lua/ui/pages-and-dispatch.md`.
- **ALT** is K1 held, the only way into ALT. Every ALT+K2/ALT+K3 action goes through `alt_action(page, n)`, never `alt_key` directly; a key pressed with ALT releases through `alt_key_release`, never `key_release`; a release acts only on the page it went down on. Release-time exceptions (`S.lib.ui_alt.k2_down`/`k2_up`, BUFFER, SCENES): `docs/notes/lua/ui/alt-and-keys.md`.
- **Encoder and ring changes** never call `params:delta`: a page's `enc` calls `enc_param_delta(n, id, d)`, rings `arc_sweep_param` or `delta_with_detent`, a binary VOICE row `set_binary_param`. Fine adjustment is ALT+E3 only; a range through 0 lands and holds on 0 (`docs/notes/lua/ui/detents-and-fine.md`).
- **Redraws**: when state the screen or arc shows changes, call `request_redraw()` (`S.lib.ui_frame.request_screen_redraw()` for a frequent change no arc ring shows); never call `redraw()` or `arc_redraw()` from script code, nor `request_redraw()` from a page's `draw()`. Grid redraws stay direct (`grid_redraw()`) (`docs/notes/lua/ui/redraws.md`).
- **Header and hints**: `redraw()` draws the header (y=8, `draw_header()`, positions in `S.constants.HEADER`) and the hint row (y=62); a page never calls `draw_hints`. Transient messages go through `S.lib.ui_flash`, never a page's own flash clock. Indicators use `[BRACKETS]` (`docs/notes/lua/ui/header-and-flashes.md`; MAIN's columns: `docs/notes/lua/pages/main.md`).
- **Cursors other modules move** go through their owner: the VOICE cursor through `S.lib.ui_cursors` (`sync`, `place`, `move`; never `clamp_all()` alone or a bare assignment), the SCENES cursor through `S.lib.pages_scenes.move_cursor` (`docs/notes/lua/pages/scenes.md`), row pages through `S.lib.ui_field_list`. A ring never reaches into a page's state (`docs/notes/lua/ui/field-list-and-cursors.md`).
- A new voice type needs a `MAIN_PARAMS` entry (E3, the MAIN display and arc ring 2 follow; `list_name` is its voice-list name, at most 5 characters) and `get_param_spec()` specs.
- The layout tests check every page for overlapping strings, text off-screen, the hint row and the MAIN divider; keep them passing. They miss strings crowding on nearby baselines and text over a rect or line: look at the page renders after a layout change (`docs/notes/lua/ui/layout-and-renders.md`).
- Before finishing, check that new values are visible with units, hints match the keys, all 7 voices fit, and nothing leaves 128×64.

### CRITICAL: keep grid and arc in step with the code

Details: `docs/notes/lua/grid-core.md`, each layout's `docs/notes/lua/grid/layout_<size>.md`, `docs/notes/lua/sequencer.md`, `docs/notes/lua/arc-core.md` and `docs/notes/lua/arc-pages.md`.
- Grid layouts are one file each (`lib/grid/layout_256.lua`, ...), registering `{key, redraw}` in `S.registry.grid_layouts` and picked by the exact `cols`/`rows` in `grid_layout()`. Patterns are `S.patterns[voice][step]` (`lib/sequencer.lua`). Anything the grid shows must call `grid_redraw()` when it changes, wherever it changes (cheap without a grid).
- Grid state is per port (`S.lib.grid_core.page(port)`, `any_page(n)`, `S.grid_held[port]`, `port_state(port)`): no global grid page, and no per-grid state in a layout local or on `S`. Pattern keys go through `step_key`, scene saves through `scene_save_key`, delayed key actions through `on_hold`, a whole-pattern replacement through `S.lib.sequencer.replace_pattern` (`docs/notes/lua/grid-core.md`).
- A grid's position page (page 5 on every layout, `POSITION_PAGE` in `lib/playheads.lua`) repaints from the playheads' 15 Hz clock when `S.lib.positions.display_signature()` changes; param actions never redraw it (`docs/notes/lua/playheads.md`).
- New params in `param_order` appear on the fader pages automatically (`fader_param_ids`, following the controlspec warp). Review whether a feature needs grid buttons or LED feedback on every layout.
- Arc: review whether new params belong on a page's rings (set only in `lib/arc/<page>.lua`). Ring feedback uses the param specs' ranges (`param_fraction`).
- Everything must degrade gracefully when no grid, arc or MIDI device is connected. Update `docs/user/grid.md` or the layout's `docs/user/grid/<size>.md`, `docs/user/arc.md` and the matching notes file with new patterns.

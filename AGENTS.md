# AGENTS.md

This file gives coding agents guidance for working in this repository. It is an index: the rules every change needs, the engine command interface and how to run the checks. Each module's details are in its own notes file (see the module table): read that file before changing the module.

**Keep this file short**: every agent loads all of it, and a test fails above 8,000 words. A rule here is one or two lines naming the notes file whose "Must not break" list holds the detail; history belongs in `docs/history.md`, and how something works in its module's notes.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns (its features: README.md and the user pages under docs/user/). The current release is 3.8.0 (see CHANGELOG.md).

**Where things are documented:**
- `docs/status.md`: **read first.** The open items (with GitHub issues) and the limits to plan around. Update it at the end of each piece of work.
- `ROADMAP.md`: the order and scope of the coming releases, and what has shipped. `docs/history.md`: each release in a paragraph, and how it was built. CHANGELOG.md: every change of every release.
- docs/design/: one design per release (`docs/design/3.4-design.md`, ...), written before its code and history once it ships. `docs/design/3.0-design.md` is still the reference for behavior; where the code differs, CHANGELOG.md's 3.0 "Deviations from the design" and later entries say how.
- docs/decisions/: the decisions taken during development, one file per release line, each with what it costs if wrong (`docs/decisions/README.md`). Add a release's decisions there.
- docs/notes/lua/: the Lua notes, one file per module (the module table below says which). Each opens with "Must not break", then what the module owns and how it works.
- docs/notes/engine/: the engine notes, one file per area of the engine check, each opening with "Must not break": `docs/notes/engine/structure.md`, `docs/notes/engine/voices.md`, `docs/notes/engine/grains.md`, `docs/notes/engine/lifecycle.md`, `docs/notes/engine/memory.md`, `docs/notes/engine/performance.md`, `docs/notes/engine/buffers.md`, `docs/notes/engine/files.md`, `docs/notes/engine/record.md`, `docs/notes/engine/waveform.md`, `docs/notes/engine/positions.md`, `docs/notes/engine/loops.md`, `docs/notes/engine/effects.md`, `docs/notes/engine/delay.md`, `docs/notes/engine/shimmer.md`, `docs/notes/engine/mix.md`, `docs/notes/engine/rings.md`, `docs/notes/engine/outrings.md`, `docs/notes/engine/freeze.md`, `docs/notes/engine/variation.md`, `docs/notes/engine/modulation.md`, `docs/notes/engine/envelopes.md`, `docs/notes/engine/notes.md`, `docs/notes/engine/onsets.md`, `docs/notes/engine/types.md`, `docs/notes/engine/tuning.md`.
- `docs/checks.md`: how to run every check, what each needs, and CI.
- `docs/notes/test-harness.md`: how the test harness works (the stubs, the runner, the engine check's runner).
- `docs/workflow.md`: how a session runs work packages through agents (the skills at each step, the controller, workers and reviewers, the ledger, briefs, reports, landing, a release's steps).
- README.md: a short overview, quick start and index of the user documentation, which is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, `docs/user/arc.md`, `docs/user/params.md`, ...).

## How work is done: the superpowers skills

Every piece of work runs on the superpowers skills: the session doing a step invokes its skill with the Skill tool at that step and on every resume, and following a skill from memory does not count. `docs/workflow.md` says who invokes each and when (Skills) and gives the lines every worker's dispatch carries (Dispatch); where a skill differs from it or this file, those win (parallel packages, batch landings, rebase-only merges).

- **A new design**: `superpowers:brainstorming`.
- **A plan**: `superpowers:writing-plans`.
- **A worktree**: `superpowers:using-git-worktrees`.
- **Running a plan or a batch**, at its start and on every resume: `superpowers:subagent-driven-development`.
- **Sending two or more agents at once**: `superpowers:dispatching-parallel-agents`.
- **Changing code or tests** (every worker): `superpowers:test-driven-development`.
- **A test or check that fails unexpectedly, or a bug**, before any fix: `superpowers:systematic-debugging`.
- **A review outside a plan's task loop** (a design, a docs change, a release): `superpowers:requesting-code-review`.
- **Acting on a review's findings**: `superpowers:receiving-code-review`.
- **Before reporting a status, landing or merging**: `superpowers:verification-before-completion`.
- **The end of a plan** (pull request only): `superpowers:finishing-a-development-branch`.

A worker's report lists the skills it invoked, and a review fails a package missing one its work required.

## Architecture

The project is written in two languages that must stay in sync:
1. **`strata.lua` and its `lib/*.lua` modules** (the norns script): UI, params, encoders/keys, grid, arc, MIDI and LFOs. They control the engine through `engine.*` commands.
2. **`lib/Engine_Strata.sc` and its `lib/engine/Strata*.sc` class extensions** (the SuperCollider engine): all synthesis and audio processing. It exposes commands with `this.addCommand()`. `lib/Engine_Strata.sc` holds only the class, every variable, `*new` and a generic `alloc` and `free`; all other code is in `lib/engine/`, a file for each area or set of defs.
   - The engine is built from **areas** (`strataArea<Name>` methods returning hooks, `voiceHit` among them, and an `order`; state in `areaState[\<name>]`): `free` runs every `stop` before any `free`, so a node never goes in `free`, a bus or buffer never in `stop`. Details: `docs/notes/engine/structure.md` (Areas).
   - Engine files are named `Strata*.sc` and extension files add methods only, never variables. Renaming or deleting an engine file needs a norns restart note in the changelog fragment.

```
Voice Synth → Voice Bus → Ring Writer → Voice Ring → strataGrainRing → Synth Path ┐
                                                                                   ├→ strataVoiceMix (voice filter, level on the other path, sends) → Main Bus (dry) + Delay Send + Reverb Send → Filter ×3 → Delay → Reverb → Master (drift/limiter/saturation) → Output
Buffer source:  Buffer pair (L/R) → strataGrainBuf → Other Path ──────────────────┤   (the stage mirrors the other path to the Voice Bus → Mod Synth, and writes the voice tap)
Input source:   SoundIn → strataInput → Input Bus → Ring Writer → Input Ring → strataGrainRing → Other Path ┘

Voice Bus → Mod Synth → Mod Bus → Other Voice Synths (cross-modulation, 3 slots per voice)
```

### Modules, notes and tests

A top-level module `lib/<name>.lua` the table leaves out is `S.lib.<name>`, its notes `docs/notes/lua/<name>.md` (underscores as hyphens), its tests `test/unit/<name>_test.lua`. This holds for top-level modules only: a module in a subfolder of lib/ keeps a row of its own. Every module, in include order: `docs/notes/lua/state-and-voices.md` (The module table).

| Module | S.lib name | Notes | Unit tests |
|--------|--------------|-------|------------|
| `strata.lua` (entry points) | | `docs/notes/lua/state-and-voices.md` | strata_test.lua, structure_test.lua |
| `lib/state.lua`, `lib/constants.lua` | S itself, S.constants | `docs/notes/lua/state-and-voices.md` | structure_test.lua, registries_test.lua |
| `lib/voices.lua` | `voices` | `docs/notes/lua/state-and-voices.md` | voices_test.lua |
| `lib/types/<key>.lua` (one per voice type, in type order) | `types_<key>` | `docs/notes/lua/types.md` | types_test.lua, types_<key>_test.lua |
| `lib/ui/frame.lua` | `ui_frame` | `docs/notes/lua/ui-core.md` | ui_test.lua, ui_layout_test.lua |
| `lib/side_files.lua` | `side_files` | `docs/notes/lua/data-files.md` (Side files) | side_files_test.lua |
| `lib/midi_in.lua` | `midi_in` | `docs/notes/lua/midi.md` | midi_in_test.lua |
| `lib/ui/modal.lua` | `ui_modal` | `docs/notes/lua/ui/pages-and-dispatch.md` | ui_modal_test.lua |
| `lib/io/<name>.lua`: `rig`, `ports` (before `lib/midi_in.lua`), `actions`, `keyed`, `targets`, `midi_out`, `crow`, `ii`, `jf`, `wsyn`, `wtape`, `er301`, `txo`, `nb`, `controllers`, `remote`, `osc`, `tape` | `io_<name>` | `docs/notes/lua/io/<name>.md` | io_<name>_test.lua |
| `lib/params_setup.lua` | `params_setup` | `docs/notes/lua/params.md` | params_setup_test.lua |
| `lib/ui/params.lua`, `lib/ui/header.lua`, `lib/ui/flash.lua`, `lib/ui/text.lua`, `lib/ui/keys.lua`, `lib/ui/menu_watch.lua` | `ui_params`, `ui_header`, `ui_flash`, `ui_text`, `ui_keys`, `ui_menu_watch` | `docs/notes/lua/ui-core.md` | ui_test.lua, ui_header_test.lua, ui_pages_test.lua |
| `lib/ui/field_list.lua` | `ui_field_list` | `docs/notes/lua/ui-core.md` | ui_field_list_test.lua |
| `lib/ui/voice_rows.lua`, `lib/ui/cursors.lua` | `ui_voice_rows`, `ui_cursors` | `docs/notes/lua/ui-core.md` | ui_cursors_test.lua |
| `lib/ui/alt.lua` | `ui_alt` | `docs/notes/lua/ui-core.md` | ui_alt_test.lua |
| `lib/ui/detent.lua` | `ui_detent` | `docs/notes/lua/ui-core.md` | ui_detent_test.lua |
| `lib/ui/name_entry.lua` | `ui_name_entry` | `docs/notes/lua/ui/name-entry.md` | ui_name_entry_test.lua |
| `lib/ui/zones.lua` | `ui_zones` | `docs/notes/lua/ui-core.md` (The zones editor) | ui_zones_test.lua |
| `lib/ui/slice_editor.lua` | `ui_slice_editor` | `docs/notes/lua/ui/slice-editor.md` | ui_slice_editor_test.lua |
| `lib/ui/voice_picker.lua` | `ui_voice_picker` | `docs/notes/lua/ui/voice-picker.md` | ui_voice_picker_test.lua |
| `lib/ui/scale_editor.lua` | `ui_scale_editor` | `docs/notes/lua/ui/scale-editor.md` | ui_scale_editor_test.lua |
| `lib/pages/<page>.lua`: `main`, `voice`, `seq`, `fx`, `lfo`, `mod`, `buffer`, `scenes`, `setup`, `io` | `pages_<page>` (`pages_main`, ...) | `docs/notes/lua/pages/<page>.md` (`docs/notes/lua/pages/main.md`, ...) | pages_<page>_test.lua (pages_main_test.lua, ...) |
| `lib/arc/core.lua` | `arc_core` | `docs/notes/lua/arc-core.md` | arc_core_test.lua |
| `lib/arc/main.lua`, `lib/arc/voice.lua`, `lib/arc/seq.lua`, `lib/arc/fx.lua`, `lib/arc/lfo.lua`, `lib/arc/mod.lua`, `lib/arc/buffer.lua`, `lib/arc/scenes.lua`, `lib/arc/io.lua` | `arc_main`, `arc_voice`, `arc_seq`, `arc_fx`, `arc_lfo`, `arc_mod`, `arc_buffer`, `arc_scenes`, `arc_io` | `docs/notes/lua/arc-pages.md` | arc_pages_test.lua |
| `lib/grid/core.lua`, `lib/grid/faders.lua` | `grid_core`, `grid_faders` | `docs/notes/lua/grid-core.md` | grid_core_test.lua |
| `lib/grid/pane.lua` | `grid_pane` | `docs/notes/lua/grid/pane.md` | grid_pane_test.lua |
| `lib/grid/pages/<page>.lua`: `patterns`, `faders`, `scenes`, `sources`, `positions`, `voices`, `fx` | `grid_pages_<page>` (`grid_pages_patterns`, ...) | `docs/notes/lua/grid/pages/<page>.md` | grid_pages_<page>_test.lua |
| `lib/grid/layout_<size>.lua`: `256`, `128h`, `128v`, `64` | `grid_layout_<size>` (`grid_layout_256`, ...) | `docs/notes/lua/grid/layout_<size>.md` (`docs/notes/lua/grid/layout_256.md`, ...) | grid_layout_<size>_test.lua (grid_layout_256_test.lua, ...) |
| `lib/Engine_Strata.sc`, `lib/engine/Strata*.sc` (an area, or a set of defs, a file) | | `docs/notes/engine/<area>.md`, one per check area | `test/engine_check.scd` (the engine check's runner) and `test/engine_check/<area>.scd` |
| the test harness (`test/norns_stubs.lua`, `test/sync_check.lua`, ...) | | `docs/notes/test-harness.md` | stubs_test.lua, docs_test.lua |
| the page renders (`test/render_pages.lua`, `test/render_pages.py`, run on demand) | | `docs/notes/lua/ui/layout-and-renders.md` | ui_layout_test.lua (the JSON dump) |

Each screen page, grid page, grid layout and the arc's page rings have their own user page (`docs/user/pages/<page>.md`, `docs/user/grid/pages/<page>.md`, `docs/user/grid/<size>.md`, `docs/user/arc.md`), notes file and unit test file, so the work on one page or layout edits only its own files. The release history and future ideas are in `docs/history.md`.

### Lua modules and `S`

Details, and how to register each kind of record: `docs/notes/lua/state-and-voices.md` (Modules and `S`).
- `strata.lua` holds only the entry points (`S`, one `include` per module, `init`, `redraw`, `enc`, `key`, `cleanup`, and the start steps only the script can own). Everything else is in `lib/`.
- **`S`** (`lib/state.lua`) is built fresh on every load. State more than one module uses is a field of `S` under its plain name; state one module uses stays local to it. `S.constants` is `lib/constants.lua`.
- **Includes**: only `strata.lua` calls `include`, once per module, always as `include("lib/<path>")`, never `"strata/lib/..."` (a test checks).
- **A module** is a constructor, `return function(S) local M = {} ... return M end`, ending with exactly `  return M` and `end`; its table is `S.lib.<name>`, or `S.lib.<dir>_<basename>` in a subfolder. Functions that were global stay global, in their module (`MODULE_HOMES`).
- **Registries** (`S.registry`) are read at init or at each use, never at include time: nine close at init, the other 25 stay open, and each `S.register_*` function checks its argument and refuses a duplicate name. The list, record shapes and which close: `docs/notes/lua/state-and-voices.md` (Modules and `S`).
- **`S.performance`** is the tier the engine runs (`lib/performance.lua` reads the engine's `performance_active.data`). Every tier-dependent spec reads it; the setting itself (`performance.data`) is SETUP's, never a param.
- Tests reach script state with `local_value(name)` and `find_upvalue(name)`: a field of `S`, then of `S.constants`, then an upvalue of a global function.

### Lua ↔ SuperCollider Communication

**IMPORTANT**: this table is the engine command interface, exactly one row per `addCommand` (a test checks signature and argument count) in the format `` | `engine.<name>(<args>)` | `"<sig>"` | purpose | ``, changed in the engine's commit; no `engine.<name>(` in the maintained docs names a gone command. A row gives each argument's range and values; the area notes under docs/notes/engine/ say what it does.

| Lua Command | SC Signature | Purpose |
|-------------|--------------|---------|
| `engine.voiceOn(voice, freq, amp, pan, grainSize, grainDensity, pitchShift)` | `"iffffff"` | Start a voice (resets `bend` to 1). Never stacks: synths still running or releasing are re-gated |
| `engine.voiceOff(voice)` | `"i"` | Stop a voice (release envelope) |
| `engine.retrigger(voice, velocity)` | `"if"` | Accent a running voice at velocity 0-1 (Karplus re-plucks; one grain in triggered mode). Creates no nodes |
| `engine.setVoiceParam(voice, param, value)` | `"isf"` | Set a synthesis param, or `bend` (MIDI pitchbend ratio) |
| `engine.setGrainParam(voice, param, value)` | `"isf"` | Set a grain param (`windowShape` 0-1, `windowSkew` -1..1, `grainProb` 0-1, `overlapOn` 0/1, `grainOverlap`, `arpOn` and `arpFold` 0/1, `grainMode` 0 continuous / 1 triggered, `bufPos`, `freeze` 0/1, `freezeMode` 0 hold / 1 spectral, `t_scanReset` not stored, `scrubRate` and `scanHold` transient, `scanMode` 0 wrap / 1 bounce / 2 one shot, `regionStart` and `regionLength` 0-1, `followRate` 0.25-4, handler-only `rootNote` and `inputChannel` 0 stereo / 1 left / 2 right (rounded, clipped), the stage's `dry` 0-1, ...) |
| `engine.setMasterDrift(amount)` | `"f"` | Global tape drift |
| `engine.setReverb(mix, size, damp, delayToReverb)` | `"ffff"` | Reverb: level 0-1 (the return), size 0-1, damping 0-1, delayToReverb 0-1. `FreeVerb2` on standard, the FDN on high. All four kept while bypassed |
| `engine.setShimmer(delayAmount, reverbAmount, ratio)` | `"fff"` | Shimmer: the delay's feedback blend 0-1 and the reverb's loop 0-1 (0 = none, the effect as without shimmer), shifted by the ratio 0.5-4 (Lua sends 0.5, 1.5, 2, 3 or 4). Kept while bypassed |
| `engine.setFilter(freq, res, type, mix)` | `"ffif"` | Master filter, one instance on each bus it filters, before the effects (dry, delay send, reverb send; never the returns): 20-20000 Hz, res 0-1, type 0 LP / 1 HP / 2 BP, mix 0 = bypass |
| `engine.setDelay(time, feedback, mix, pingPong)` | `"ffff"` | Master delay: 0.01-5.4 s, feedback 0-0.95, level 0-1 (the return; 0 = silent, the node keeps running), pingPong 0-1. Kept while bypassed |
| `engine.setDelayFreeze(frozen)` | `"i"` | Freeze the delay's loop (1) or release it (0) over 20 ms: feedback exactly 1, input closed, time held and rounded to whole samples, ping-pong snapped to 0 or 1. Others ignored. A bypass releases it |
| `engine.clearDelay()` | `""` | Empty the delay: its feedback and return muted for the delay time and 5 ms, so the line refills with what comes in. Nothing while bypassed |
| `engine.setBypass(effect, bypassed)` | `"ii"` | Effect 0 delay / 1 reverb (others ignored), bypassed 0 or 1: frees the node after its fade and re-creates it in its place when lifted. Only this frees an effect |
| `engine.setModSource(voice, slot, sourceVoice)` | `"iii"` | Crossmod source for slot 1-3 (-1 = none → `silentBus`, 0-6 = voice). The three crossmod commands ignore any other slot |
| `engine.setModAmpAmt(voice, slot, amount)` | `"iif"` | Crossmod amplitude depth (-2 to 2) |
| `engine.setModFreqAmt(voice, slot, amount)` | `"iif"` | Crossmod frequency depth (-2 to 2) |
| `engine.setModSpeed(voice, speed)` | `"if"` | Mod signal LFO speed (0.1-50), kept per voice |
| `engine.setGrainSource(voice, source)` | `"ii"` | 0 = synth, 1-8 = buffer slot, 9 = input, 10-16 = voice 1-7's output ring. Replaces a running voice's grain synth (never stacks), records a stopped voice's choice; same source = no-op |
| `engine.setVoiceType(voice, type)` | `"ii"` | Voice 0-6's synth: type 0 to `numVoiceTypes` - 1 (`voiceTypeDefs`' order). Cuts and replaces a running synth voice's voice synth (never stacks), records any other voice's and a spectral-frozen voice's until its unfreeze; same type = no-op |
| `engine.loadBuffer(slot, path, start)` | `"isf"` | Read a file into slot 0-7 from `start` seconds into it (at the file's rate; 0 = the beginning), at most `bufferSeconds` at the server rate; voices reading the slot fade first. A failure is reported on `bufferLoadFailed`. `docs/notes/engine/buffers.md` |
| `engine.recordBuffer(slot, seconds, level, feedback, source, threshold, loop, delay, sent)` | `"ifffififf"` | Record `source` (0 input, 1 pre-master, 2 post-master, 3-9 voice 1-7; others input) × `level` into slot 0-7 for `seconds` (at most `bufferSeconds`): each frame keeps the old audio × `feedback` (0 with `loop` 0 is a replace take), `loop` 0/1, `threshold` linear (0 = none), starting `delay` s after `sent` (`util.time() % 1000`). States on `recordState`. `docs/notes/engine/record.md` |
| `engine.clearBuffer(slot)` | `"i"` | Zero slot 0-7 after its voices fade (cancels a recording) |
| `engine.stopRecord(slot)` | `"i"` | End slot 0-7's recording now, with its 5 ms fade, and keep what was captured; an armed one that has not started is canceled. No-op without one. `docs/notes/engine/record.md` |
| `engine.saveBuffer(slot, path, start, length)` | `"isff"` | Write `[start, start + length)` of the slot's valid region (fractions; 0, 1 = all of it) as a stereo 16-bit WAV. The outcome is reported on `bufferSaveResult`. `docs/notes/engine/files.md` |
| `engine.analyzeBuffer(slot)` | `"i"` | The transients of slot 0-7, reported on `bufferOnsets`. `docs/notes/engine/onsets.md` |
| `engine.setScale(root, mask)` | `"ii"` | The scale every quantized grain lands on: root 0-11 (0 = C), mask 1-4095, a 12-bit pitch-class set from the root (4095 = chromatic, the default), applied in a tuning of twelve tones to an octave. Other values are ignored |
| `engine.setTuning(count, period)` | `"if"` | Begin the tuning quantized grains land on: count 1-128 tones a period of 100-4800 cents. Its tones follow as `setTuningTone`; the last rebuilds the table |
| `engine.setTuningTone(index, cents)` | `"if"` | Tone index 0 to count - 1 of the set `setTuning` began, in cents: tone 0 is 0, each above the last, all below the period. A set that breaks this keeps the old tuning |
| `engine.setFastLfo(lfo, voice, destination, shape, rate, depth, offset)` | `"iiiifff"` | Engine LFO 0-5 on voice 0-6's fast destination 0-4 (pitch, position, size, cutoff, amp): shape 0-7 (sine, tri, square, up, down, s&h, smooth, drunk), rate 0.003-50 Hz, depth 0-1, offset -2..2 (half ranges). Never more than one node per LFO |
| `engine.stopFastLfo(lfo)` | `"i"` | Release LFO 0-5's node (20 ms) and zero its channel. No-op without one |
| `engine.syncFastLfo(lfo, phase)` | `"if"` | Set LFO 0-5's phase (0-1) now. No-op without a node |
| `engine.setScatter(depth, rate, destinations, voices)` | `"ffii"` | Scatter: depth 0-1 (0 releases the node), rate 0.01-1 Hz, destinations a 5-bit mask (bit d = destination d), voices a 7-bit mask (bit v = voice v) |
| `engine.setFastOffset(voice, noteSlot, destination, offset)` | `"iiif"` | Set the Lua-computed offset (-2..2 half ranges, clamped) on voice 0-6's note slot (0 in 3.4; 0..`fastModNoteSlots` - 1) and fast destination 0-4, lagged 50 ms. Creates no node |
| `engine.setFastEnv(route, source, voice, destination, depth, attack, decay, sustain, release, curve, loop)` | `"iiiiffffffi"` | Route 0-15, fired by voice 0-6's hits, on voice 0-6's fast destination 0-4: depth -2..2, attack, decay and release 0.001-10 s, sustain 0-1, curve -8..8, loop 0/1 |
| `engine.stopFastEnv(route)` | `"i"` | Release route 0-15's node (20 ms). No-op without one |
| `engine.noteOn(voice, slot, note, freq, rate, velocity)` | `"iiffff"` | Start voice 0-6's note slot 0-7 (0 its own note, 1-7 extra): note -24..151, freq 8-20000 Hz, rate 0.25-4, velocity 0-1 |
| `engine.noteOff(voice, slot, cut)` | `"iii"` | End voice 0-6's slot 0-7: cut 0 releases, 1 cuts (50 ms) |
| `engine.noteExpression(voice, slot, bend, amp, position, size, main)` | `"iifffff"` | Voice 0-6's slot 0-7 expression: bend ratio 0.0625-16, amp 0-2, position, size and main -1..1 half ranges. Creates no node |
| `engine.setNotePool(size)` | `"i"` | The extra notes all voices share, 0-16 (`notePoolMax`) |
| `engine.noteRegion(voice, slot, start, length)` | `"iiff"` | Voice 0-6's extra slot 1-7: start and length 0-1 of the valid region (length 0 = the loop) |
| `engine.syncScan(voice, phase)` | `"if"` | Voice 0-6's own scan phase, 0-2 passes |
| `engine.setSlotGain(slot, gain)` | `"if"` | Slot 0-7's gain, 0-16 |

**Guarded commands** ignore an out-of-range index or a non-finite continuous argument with one console line; a continuous argument out of the ranges above is clipped, or ignored alike by `setTuning` and `setTuningTone` (`docs/notes/engine/modulation.md`, `docs/notes/engine/envelopes.md`, `docs/notes/engine/notes.md`, `docs/notes/engine/positions.md`, `docs/notes/engine/effects.md`, `docs/notes/engine/tuning.md`, `docs/notes/engine/onsets.md`): `setFastLfo`, `stopFastLfo`, `syncFastLfo`, `setScatter`, `setFastOffset`, `setFastEnv`, `stopFastEnv`, `noteOn`, `noteOff`, `noteExpression`, `setNotePool`, `noteRegion`, `syncScan`, `setSlotGain`, `analyzeBuffer`, `setDelay`, `setDelayFreeze`, `setTuning`, `setTuningTone`, `setShimmer`.

**Polls** (engine → Lua) pack each report into one float, and Lua matches each report to the command it names or, for `freezeEnded`, the engine's count of the freezes it ended (`docs/notes/lua/freeze.md`): `docs/notes/engine/buffers.md` (Polls, The polls' encodings), `docs/notes/engine/record.md`, `docs/notes/lua/buffers.md` and `docs/notes/lua/record.md`.

**Index conversion**: voices are 0-indexed in SC and 1-indexed in Lua, so always pass `voice_idx - 1`. Mod sources go through `engine_mod_source()` (Lua 0 = none / 1-7 → SC -1 / 0-6).

**The `voices` table is the only source of values.** The engine holds no per-voice defaults: a start (`S.lib.engine_sync.start_voice`) sends every value, and param actions reach the engine only while a voice is active, except the `v<i>_source` and `v<i>_type` actions, which also reach stopped voices. The order: `docs/notes/lua/engine-sync.md`.

### Invariants that are easy to break

One or two lines each: the rule, then the notes file whose "Must not break" list holds the detail, the reasons and the exceptions. Read that file before changing the code a rule names.

The engine's (under docs/notes/engine/):
- **A voice's own note never creates a node** on a step or a MIDI note (`retrigger`); an extra note creates exactly one synth in its slot, through `S.lib.notes` alone. Velocity only scales the accent envelope's `levelScale` in every voice and grain SynthDef and in `\strataVoiceMix` (Karplus's pluck impulse is the one allowance). `docs/notes/engine/voices.md`, `docs/notes/lua/notes.md`
- **Replace, never stack**: a source switch replaces the grain synth; fading synths are cut with `cutSynth`, never a second `release`; new grain synths are placed with `startPlacedGrainSynth`. `docs/notes/engine/lifecycle.md`
- **A type switch cuts**: `setVoiceType` frees the voice's cutting set, cuts its voice synth (never a release) and restarts its voice-synth notes; under a spectral freeze it waits for the unfreeze; `gateVoice` re-gates a releasing voice synth only of the voice's current type. `docs/notes/engine/types.md`
- **`openedGate(gate)`** wraps every ASR gate; never `gate.max(...)`. `docs/notes/engine/lifecycle.md`
- **Silent bus**: unrouted mod slots read `silentBus`, never control bus 0. `docs/notes/engine/voices.md`
- **Limiter before the tanh saturator** in `\strataMaster`, never after it. `docs/notes/engine/effects.md`
- **One grain path**: every grain synth is a `GrainBuf` pair built by `grainBody`, pitch is the grain rate, and it writes only its source kind's path (`voicePathBus`); no grain SynthDef has a delay line, filter, send, mirror or voice-level amp, and its only gains are the note's and the slot's. `docs/notes/engine/grains.md`
- **Buffer, input and voice sources have no voice synth**: their grain synth writes the voice's other path, which the stage mirrors to `granBuses[i]` so crossmod keeps working; the synth path never mirrors, and the synth-source grain synth keeps `pan` and `rateLevel` at 0. `docs/notes/engine/grains.md`, `docs/notes/engine/mix.md`
- **One persistent stage per voice** (`\strataVoiceMix`, `effectKeys`, never re-gated), at the tail of its mix group, just before the voice's mod synth; in `processGroup`, synth-source grain synths sit at the head, buffer and input grain synths at the head of their voice's mix group. The level comes after the voice filter, on the other path only; inputs and filter outputs go through `zeroBadValues`. `docs/notes/engine/mix.md`
- **Ring writers** run at the tail of `voiceGroup` and the output rings' in the tap group (`softclip`), are persistent `effectKeys` and zero bad input; a ring grain reads behind the write head and never past the ring. `docs/notes/engine/rings.md`
- **The ring head is read sample by sample**: `ringGrainReader` starts every ring grain the lookback and one block behind the write head wherever its trigger falls in a block, so it never holds the head for a block without adding the sample's offset. `docs/notes/engine/rings.md`
- **`ringReaders`** maps every `\strataGrainRing` to its voice until it frees; only its writer writes a voice ring, the input ring or an output ring; an input freeze's copy fades the copy ring's readers first and runs only if `ringChanges[voice]` is unchanged. `docs/notes/engine/rings.md`
- **Freeze** changes a synth voice's ring writer only with `run` or `Synth.replace`; an input or voice-source freeze uses only the voice's copy ring (`copyRingFor`, `copyWriterKeys`); spectral exists on high only; a source switch unfreezes first; an unfreeze's re-point and `freeze` 0 go in one bundle; ring reads come from `grainReadPairs`. `docs/notes/engine/freeze.md`
- **No `LocalBuf` in any engine SynthDef** (a structure test enforces it). `docs/notes/engine/freeze.md`
- **Every SoundFile `readData` reads into a fresh array** (`freshReadArray`; a structure test enforces it). `docs/notes/engine/files.md`
- **No per-sample sclang loop in engine code**: build sample arrays with C primitives (a structure test enforces it in `StrataFiles.sc` and the tuning table). `docs/notes/engine/files.md`
- **Long-lived frames**: hooks, `strataAreas` and a function's call (a command, `onFree`, fork, `sched`) of a method that keeps a closure go through `areaCall` (#211; a test checks the hooks, its listed calls and every engine function, #689). `docs/notes/engine/structure.md`
- **No List that grows without bound while sclang allocates heavily** (an OSC responder, a polling loop, a long routine): make it with room for all it will hold (`List.new(n)`) or bound it. `docs/notes/engine/files.md`
- **Buffer memory**: slots of `bufferSeconds` (16 s standard, stepped down on high), voice rings and copy rings of 4 s, the input ring, and the fixed buffers `fixedBufferBytes` counts once; never allocate longer ones; bufnums never change. `docs/notes/engine/memory.md`, `docs/notes/engine/performance.md`
- **Real-time memory**: norns' pool is 8192 KB. Every `GrainBuf` uses `maxGrains` (128); never size a delay line or table from a control; a voice holds at most its live synths, one fading and one cutting set, and each extra note's slot one live and one cutting synth; the worst cases leave their floors free and every def stays under its limit. A new delay line, table or node per voice needs the budget re-measured. `docs/notes/engine/memory.md`
- **Notes**: extra notes live only in `areaState[\notes]`'s slots; a slot never holds two live synths, and live and releasing extra notes never exceed the pool; voice-wide sends reach a voice's notes through `setVoiceSynths` and `setGrainSynths`. `docs/notes/engine/notes.md`
- **Fast modulation**: every channel of `fastModBus` comes from `fastModChannel`; the buses hold offsets only and Lua owns every base value; the cutoff and amp offsets belong to the per-voice stage (`voiceMixMod`); at most one node per engine LFO and per envelope route at every moment, a releasing one included, and one scatter node; a channel is zeroed when its last writer ends. `docs/notes/engine/modulation.md`
- **The step gate and mute are the stage's** (`voiceGate`, on the whole output but the mirror): velocity never reaches the gate's envelope, which `retrigger` or an extra note's start (`t_gate`, never an accent) opens; `seqGate`, `gateSeconds`, `gateRelease` and `voiceMute` are kept in `grainControls[voice]`, which Lua relies on. `docs/notes/engine/modulation.md`
- **`slotChanges[i]`** guards late replies and the fade wait (a clear or load sent later always wins); load and save reports name their number. `docs/notes/engine/buffers.md`
- **One record synth per slot, only in the tap group** (`areaState[\record][\tapGroup]`, after the master): a new recording, load or clear frees the old one at once, even in its stop fade. A playable recording never shrinks its slot and zeroes it only through `afterSlotFade`; every delayed step of a recording runs only if `slotChanges` is unchanged. `docs/notes/engine/record.md`
- **The head guard** (`slotHeadGuard`) passes a grain's start through when the head bus reads -1, moves a start the head would meet during the grain's life to the zone's edge (never past D), and keeps it in `slotGrainPos`'s valid range. `docs/notes/engine/record.md`
- **Chunk loops in a routine** wait through `yieldToCommands`, never a plain `wait`. `docs/notes/engine/files.md`
- **Fade before zeroing**: never zero a slot directly; go through `afterSlotFade`, and fading `\strataGrainBuf`s only ever get `bufFrames 0`. `docs/notes/engine/buffers.md`
- **Messages to synths that can end on their own** go through `sendToSynth`, never `synth.set`/`release`/`free`/`moveBefore`; the effects chain's `effectKeys` get plain sends. `docs/notes/engine/lifecycle.md`
- **Bypass is explicit**: only `setBypass` frees the delay or reverb and re-creates it in its place; a mix at 0 only silences; the master filters are never freed; a bypass ends its effect's freeze first (Lua). `docs/notes/engine/effects.md`
- **Shimmer**: one audio-rate `LocalIn` a SynthDef (a loop widens it); the reverb's loop clips softly at 0.25 and its output passes `zeroBadValues`; at amount 0 each effect is its def without shimmer, bit for bit. `docs/notes/engine/shimmer.md`
- **Delay freeze and clear**: the freeze is `\strataDelay`'s `frozen` (feedback `max` the freeze, input closed, time held and rounded, ping-pong snapped), never a feedback of 1 through `setDelay`; clear mutes the feedback and the return for a delay time, never zeroes the line. `docs/notes/engine/delay.md`, `docs/notes/lua/fx-hold.md`
- **Plain sends**: a stage writes its signal times `dry` to the dry bus and times each send to its send bus, the sends taken before the dry level; the returns are levels; a stage gets its send buses through `stageControls`. `docs/notes/engine/mix.md`, `docs/notes/engine/effects.md`
- **NaN guards**: the three `\strataFilter`s (one on the dry bus and one on each send) and `\strataMod` (input and output), and the reverbs' outputs and shimmer loops, replace bad values with `zeroBadValues`. `docs/notes/engine/effects.md`, `docs/notes/engine/voices.md`
- **File writes** go to a `.part` file renamed into place, never the final path; `deleteStaleParts` deletes only old `.part` and temporary float files; a peaks write, save or scratch take renames through `renameIntoPlace`, never its own `unixCmd` or `systemCmd`. `docs/notes/engine/files.md`, `docs/notes/engine/waveform.md`
- **The peaks file is in place before the length is reported**: a load's `bufferChanged` runs as `writeSlotPeaks`' action, after the rename; a failed write still reports the length. `docs/notes/engine/waveform.md`
- **The peak scan allocates nothing per sample**: bin-aligned chunks and `Signal`'s `peak`, never `maxItem` or `minItem` (a structure test enforces it). `docs/notes/engine/waveform.md`
- **`\strataFilter`**: never compare a UGen with `==`; use `BinaryOpUGen('==', ...)`. `docs/notes/engine/effects.md`
- **The filter's highpass and cutoff**: `multimodeFilter` runs `RLPF` and `BPF` only, the highpass is the input less both (never an `RHPF`), and a cutoff rises at most `cutoffRiseRate` through `riseLimitedCutoff`. `docs/notes/engine/effects.md`
- **No slot grain reads past the valid region**, forward or reverse, whatever the loop: the loop is cut to the legal starts with audio-rate `max` and `min` (never a control-rate `Clip`), never shortens a grain, and the engine never trusts Lua's start and length pairing. `docs/notes/engine/loops.md`
- **Grain draws latch per grain**: every variation draw is a `TRand`/`TIRand` on the grain trigger feeding a `GrainBuf` input; size jitter never makes a grain longer than 0.5 s; quantize comes before bend and crossmod; `scaleBuffer`'s bufnum never changes. `docs/notes/engine/variation.md`
- **Transient scan state**: `scrubRate`, `scanHold` and `t_scanReset` are never params, scene or PSET fields (the one exception to the `voices` table holding every value); `t_scanReset` is never stored; every voice sync sends the other two as 0; every grain start restarts the scan. `docs/notes/engine/positions.md`, `docs/notes/lua/positions.md`
- **The engine runs the tier Lua reads**: `parseActivePerformance` stays identical to `S.lib.performance.parse_active_text`, the step-down arithmetic matches what the areas allocate (`fixedBufferBytes`), and the poll's slot length only ever lowers Lua's `S.performance.buffer_seconds`. `docs/notes/engine/performance.md`, `docs/notes/lua/performance.md`

The Lua side's, across modules:
- **Param → engine**: a control param's action calls `send_param_to_engine(id, value)` with an `S.engine_senders[id]` entry, never `engine.*`; a command carrying several params reads the others with `engine_param_value(id)`; LFOs never `params:set` their destination. `docs/notes/lua/engine-sync.md`, `docs/notes/lua/lfos.md`
- **Scenes**: a new captured field needs `validate_scene` coverage and a `fill_scene` default; discrete keys switch at the end of a transition, never crossfade; a recall sends one full sync per running voice whose source or type changed; a scene's synth keys are its own type's. `docs/notes/lua/scenes.md`
- **Data files** (`scenes.data`, `buffers.data`, `macros.data`, `matrix.data`, `gestures.data`, `sequences.data`, `samples.data`, `grids.data`, `notes.data`, `io.data`, `factory.data`, `voices.data`) are written only through `S.lib.data_files.write` and read only through `S.lib.data_files.read`, never `tab.save` or `tab.load`; a backup never replaces an earlier one. `docs/notes/lua/data-files.md`, `docs/notes/lua/scenes.md`, `docs/notes/lua/buffers.md`
- **Factory sets** set sound only: a line naming a `FACTORY.rig` param or norns' own is refused, and a set's files are read, never set aside. `docs/notes/lua/factory.md`
- **Source tests**: `voice_uses_synth`, `voice_uses_buffer`, `voice_uses_input`, `voice_uses_voice`, never `not voice_uses_synth` (that includes input and voice sources). `docs/notes/lua/state-and-voices.md`
- **Grid, arc and MIDI handlers live on the vport only**, never on the raw device passed to `grid.add`. `docs/notes/lua/grid-core.md`, `docs/notes/lua/arc-core.md`, `docs/notes/lua/midi.md`, `docs/notes/lua/io/ports.md`
- **MIDI ports**: only `lib/io/ports.lua` sets `midi.add`, `midi.remove` or a MIDI vport's `event`; a module listens, sends and hears of devices through `S.lib.io_ports`, and a claimed port has one owner. crow is spoken to in text through `S.lib.io_crow` (`send_now`, `send_value`), and no function is assigned through the `crow` proxy. `docs/notes/lua/io/ports.md`, `docs/notes/lua/io/crow.md`
- **Arc rings** sweep their range in 1024 ticks through `arc_sweep_param` and draw through `arc_ring_fill` from `param_fraction`, never a bare `segment` or a hardcoded range (the exceptions are SEQ's step editor and MOD's targets view); whole-step rings carry ticks through `arc_whole_steps`; Strata follows one arc. `docs/notes/lua/arc-core.md`, `docs/notes/lua/arc-pages.md`
- **Lock** (`[L]`, `toggle_lock`, the state `S.locked`): randomize, drift, mutation and scatter leave a locked voice alone, and it can still be edited; "freeze" names only the audio freeze. `docs/notes/lua/mutation.md`, `docs/notes/lua/freeze.md`
- **Randomize undo**: every page randomize (ALT+K2) goes through `S.lib.mutation.randomize(spec)`, and every param a spec draws calls `note_param_edit` from its action; there is one undo, `S.undo`, undone only where it was made (`undo_for`); a binary draw goes through `set_binary_param`. `docs/notes/lua/mutation.md`
- **LFOs**: one 48 Hz clock (`S.lfo_clock`) steps the six in index order; an LFO's destination is its home routing (slot 16 + n), played by its engine node if fast (`setFastLfo`, `stopFastLfo`, `syncFastLfo`), itself if a macro, the matrix otherwise; mod inputs read lower-numbered LFOs only. `docs/notes/lua/lfos.md`
- **Selected voice**: after init, `S.selected_voice` changes only through `S.lib.ui_keys.select_voice_by`. `docs/notes/lua/midi.md`
- **Filter restore mix**: `S.fx_last_mix.filter` changes only in `lib/params_setup.lua`, never in the FX page; the delay and reverb have none. `docs/notes/lua/pages/fx.md`
- **Per-voice params** are `S.register_voice_params` records (the built-ins `synth`, `grain`, `crossmod` first), added with `add_voice_param`; a record names the keys MAIN's randomize, the mutations and the fader pages reach (`main_randomize`, `mutate`, `fader`); registered LFO destinations join their voice's group. `docs/notes/lua/params.md`
- **Voice types**: a type is only appended, never reordered (Lua's `S.register_voice_type` order is the engine's `voiceTypeDefs`, a docs test); a synth key's sender reaches the engine only while the voice's type has it; a scene's synth keys are checked against its own `type`. `docs/notes/lua/types.md`
- **Mute and solo**: a mute silences in the mix stage (`voiceMute`, sent as `S.lib.voice_mix.silenced(voice)`, never as a stored value) and never stops a voice; scenes store mutes and never solos. `docs/notes/lua/voice-mix.md`
- **Loop pairs**: scenes set `loop_length` before `loop_start` (sorted key order), so the length's filter stands down during a recall or transition, the start's action cuts a length that does not fit, and a loaded pair goes through `normalize_scene`. `docs/notes/lua/loops.md`, `docs/notes/lua/scenes.md`
- **Scale quantize**: one `freq` filter snaps a per-voice shadow note that only a turn moves (`S.lib.ui_detent.as_turn`); every other set snaps its own value; `scaleNote` is resent whenever it moves; a voice's `quantize` loads ahead of its `freq` (`add_first`). `docs/notes/lua/variation.md`
- **Tuning**: one tuning, `S.lib.tuning`'s; every MIDI key, snap, degree and chord goes through it (`pitch_of_key`, `snap`, `step`, `allowed`); only it sends `setTuning`/`setTuningTone`; the mask applies only to twelve tones of an octave. `docs/notes/lua/tuning.md`
- **Recordings (Lua)**: the record params are PSET-only, never scene fields; only a slot's newest recording's reports act; every path that ends a recording cancels its timer through `S.lib.record.cancel_timer(slot)`; what a slot holds is `S.lib.buffers.status(slot)` and `is_free(slot)`. `docs/notes/lua/record.md`, `docs/notes/lua/buffers.md`, `docs/notes/lua/files.md`
- **Peaks and playheads**: a peaks file is read only in `lib/waveforms.lua`'s clock loop; pages and grids read the waveform, heads and bookmarks only through `S.lib.waveforms`, `S.lib.playheads` and `S.lib.positions`, and send no engine command for them. `docs/notes/lua/waveforms.md`, `docs/notes/lua/playheads.md`, `docs/notes/lua/pages/buffer.md`
- **The playhead restarts where the engine's scan does** (a `voiceOn`, a source switch through `S.register_grain_restart`, a jump); call `S.lib.playheads.advance(v)` before changing the hold or the glide's rate. `docs/notes/lua/playheads.md`
- **Jumps and recalls** enter only through `S.lib.positions.jump` and `recall_bookmark`; the scan hold, the glide and the last recalled bookmark are never params, scenes or PSETs. `docs/notes/lua/positions.md`
- **Bookmarks, 3.4's interface**: `S.lib.bookmarks.recall(v, n)` and `is_set(v, n)` keep their names and behavior and never create a node. `docs/notes/lua/bookmarks.md`
- **Macros**: a macro never targets a macro or the morph (`S.lib.macros.target_ids()` is the only list of targets); scenes, a transition and morph set a macro silently (`set_silently`); every apply's fan-out is one `deferrable`, from `S.macro_clock`; an LFO on a macro moves engine values, never a param. `docs/notes/lua/macros.md`
- **The matrix adds offsets and never sets a destination param**: a Lua destination's routings sum into `set_extra_offset("matrix", id, sum)`; a fast one reaches the engine only as `send_engine_value("matrix fast <voice> <destination>", sum)`, never `setGrainParam` or a bare `setFastOffset`; every send goes through `S.lib.lfos.mark_due`; an owned routing (`S.lib.envelopes.owns`, `S.lib.lfos.owns`) is left out of the sum. `docs/notes/lua/matrix.md`, `docs/notes/lua/envelopes.md`
- **Morph writes params and never recalls**: it never calls `recall_scene` or `recall_scene_instant`, starts a transition or clears the undo; values go through `S.lib.scenes.set_value` and `apply_entries(entries, {only = "discrete"})`, inside `deferrable`, from `S.morph_clock`; a later recall or fade wins. `docs/notes/lua/morph.md`
- **The sequencer plays only through step outputs** (`S.register_step_output`): each hit reaches every output, each in its own coroutine but `voices`, and no `play` yields. No step creates a node for the voice's own note: a stopped voice gets `start_voice` at a step's first hit, a running one `retrigger`; a chord's further notes go through `S.lib.notes`, or on an arpeggiating voice its list (`S.lib.arp`). `docs/notes/lua/sequencer.md`
- **Step locks and notes are base overrides** (`S.lib.engine_sync.set_base_override`), never `params:set`; they end at the voice's next played step without them, a stop, `replace_pattern` or a shorter length. `docs/notes/lua/sequencer.md`
- **Strata follows the transport and never leads it**: `clock.transport` start and stop move the patterns only while `seq_follow_transport` is on; nothing calls the clock's own start or stop; a clock tests the beat its `clock.sync` returned, never the live beat. `docs/notes/lua/sequencer.md`
- **Notes** are played, released and expressed only through `S.lib.notes`, which alone calls `noteOn`, `noteOff`, `noteExpression`, `noteRegion` and `setNotePool`; its flush sends at most 16 `noteExpression` a step, counted (`count_sends`), never deferred. `docs/notes/lua/notes.md`
- **Slices**: a slice is played only through `S.lib.slices.play`; a one-voice step sets the own region through `S.lib.notes.set_own_region`; a missing slice plays nothing. `docs/notes/lua/slices.md`
- **Targets**: a voice's external notes start, end and are expressed only through `S.lib.io_targets`; an off goes to exactly the targets its on went to, and a voice's stop, a route change, a mute and cleanup end every note, the patterns' stop its step notes. Every ii message goes through `S.lib.io_ii`, which sends none unless Strata leads the bus. `docs/notes/lua/io/targets.md`, `docs/notes/lua/io/ii.md`

## Working in parallel

Several pull requests are built at once, often by agents, each in files only its work edits but for one-line registrations; `docs/workflow.md` says how a session runs them. The rules every change follows:
- **Rebase, never merge main in**: `git fetch -q origin && git rebase origin/main`, then `git push --force-with-lease`; never `git merge origin/main` or `gh pr update-branch` without `--rebase`. Pull requests merge with `gh pr merge --rebase`; a worker rebases only when the controller asks (`docs/workflow.md`, Landing in batches).
- **One worktree per pull request**, from an up-to-date `main`, never shared; engine checks in different worktrees use different `$STRATA_SC_PORT` ports.
- **Own scratch folder and worktree, nothing else**: never touch another worker's folder, worktree, logs or containers; remove only a worktree you created, with `git worktree remove`. The ledger stays in the main checkout (`docs/workflow.md`).
- **Edit only the files your package owns** (its design or brief lists them), plus registration lines and its own notes file, unit test file and `docs/user/` page; ask for any other change, or make it a separate pull request.
- **Registering** is a few lines in the owning module: a page (`docs/notes/lua/ui/pages-and-dispatch.md`), params (`docs/notes/lua/params.md`, Registering params), a start or cleanup step (`docs/notes/lua/state-and-voices.md`), a grid page or layout (`docs/notes/lua/grid/pane.md`), an engine area (`docs/notes/engine/structure.md`, Areas). `init`, `cleanup()` and `lib/Engine_Strata.sc` are never edited.
- **On a conflict in a registration line** (an include, a `UI_PAGES`, `START_ORDER` or `CLEANUP_ORDER` entry, a `register_params` call, a row or rule of this file): keep both, in the order the sequence needs, and rerun the checks; of two `START_ORDER` or `CLEANUP_ORDER` entries on one number, the later takes a free one.
- **Shared files** (CHANGELOG.md, `docs/status.md`, this file, README.md, `ROADMAP.md`, `docs/history.md`): edit them only where your package needs to. A feature pull request never edits CHANGELOG.md.
- **Changelog**: every pull request adds a changelog fragment `changes/<branch-name>.md`; see `changes/README.md`. The release pull request merges the fragments into CHANGELOG.md.

## Development & Testing

How to run each check, what it needs and how CI runs them: `docs/checks.md`. How the harness works: `docs/notes/test-harness.md`.

**On norns:** copy the project to `~/dust/code/`, then restart norns from its menu (SYSTEM > RESTART): every engine change needs it. maiden's `;restart` restarts only matron, norns' Lua side, so it never picks up an engine change.

**Off-device checks** (run from the repo root before committing; CI runs all three):
- `lua test/run.lua` and `luajit test/run.lua`: the behavior tests against norns stubs, one file per module under test/unit/; `lua test/run.lua <filter>` runs the files whose name contains `<filter>`. Run your module's file while you work and the whole suite before pushing. The run includes the sync check, the docs checks, the changelog fragment check and the module safety nets (`docs/notes/test-harness/run-and-helpers.md`); the engine stub rejects any `engine.*` call the engine source would not take (`docs/notes/test-harness/engine-stub-and-sync.md`).
- `lua test/sync_check.lua`: every `engine.<name>(...)` call has a matching `addCommand`, and every command is used but those in its `PENDING_COMMANDS`. Call engine commands only as `engine.<name>(...)`, never through another use of `engine`.
- `test/run_engine_check.sh [path/to/norns]`: compiles the engine against norns `sc/core` and runs the area files `test/engine_check/<area>.scd` on a silent scsynth. `STRATA_ENGINE_CHECK_AREAS=memory` runs only the areas it names: work on an area with its own run, and run all areas before pushing (CI's shards: about 30 minutes of areas). Give each worktree's runs their own `$STRATA_SC_PORT` (default 57110; avoid 57120 and the few above it). A new area adds its file, its name in `areaOrder` and its notes file.
- `test/run_engine_check_313.sh [-s version] [-n runs] [-j parallel] [-o log_dir] [-1] [-l] [-c] [path/to/norns]`: the engine check in Docker on SuperCollider 3.13 (CI's; `-s 3.14`: 3.14.1), as CI's shards (from `.github/workflows/test.yml`); `-1` runs it in one sclang, `-l` prints the shards, `-c` classifies a log folder (`docs/notes/test-harness/engine-check-runner.md`).
- Page renders, on demand (`lua test/render_pages.lua <dir>`, then `python3 test/render_pages.py <dir> --font ~/src/norns/resources/norns.ttf`): look at them after a layout change (`docs/notes/lua/ui/layout-and-renders.md`).
- Add a test to the unit file of the module you change, for every behavior change; a name the tests reach (`local_value()`, `find_upvalue()`) stays a field of `S` or `S.constants`.
- The stubs mirror the real norns libraries (`~/src/norns/lua`): check there before changing them (`docs/notes/test-harness/stubs.md`). `param.t` holds numeric type codes: never compare it with a string.
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file (norns compiles every `.sc` under `~/dust`).

**Common norns pitfalls:**
- `UI.List` has no `set_items()`: recreate the list. `UI.List.new(x, y, index, items)` needs every argument.
- `clock.sleep()` works only inside `clock.run(...)`. Never call it in `init()`.
- Param IDs must be unique, and norns has built-ins such as `reverb`. Use prefixed ids (`strata_fx`, ...).
- A group's size `n` must equal the number of params that follow it. Groups cannot nest.

## Code Style Guidelines

**Named constants, never magic numbers.** They live in `lib/constants.lua` (`S.constants`, aliased as locals in each module using them), among them `NUM_VOICES` (7), `NUM_SCENES` (16), `PATTERN_LENGTH` (16), `SCENE_DATA_VERSION` (10), `NUM_MOD_SLOTS` (3), `NUM_UI_PAGES` (10, `#UI_PAGES`), `MAX_STEP_LEVEL` (15), `NUM_BUFFERS` (8), `NUM_LFOS` (6), `NOTE_SLOTS` (8) and `NORNS_SAMPLE_RATE` (48000); the others are listed in `docs/notes/lua/state-and-voices.md` (Owns). The engine mirrors several, and docs tests compare them (`docs/checks.md`, The Lua tests). The slot length is a tier value, not a constant: read `S.performance.buffer_seconds`. Never hardcode 7, 8 or 16 in voice, scene, pattern or buffer code (bare numbers in grid code are coordinates and LED levels).

**Lua's 200-local limit applies to each function, checked by a test**: every file's main chunk and every module constructor keeps at least 30 locals free; group a feature's constants in one table (`LFO_PAGE`, ...) and split a module that runs short (`docs/notes/lua/state-and-voices.md`).

**Descriptive names**: `selected_voice`, not `sv`; `master_density`, not `md`.

**Bounds-check every index** (voice 1..`NUM_VOICES`, scene, step, slot, grid coordinates) before indexing. **Clean up** every metro, clock, poll and device handler through `S.register_cleanup` at its place in `S.constants.CLEANUP_ORDER`, never code in `cleanup()`; cancel a clock before starting its replacement (`docs/notes/lua/state-and-voices.md`).

**No unguarded recursive deletes**, in code or in your shell: tests delete only through `h.remove_tree`; a command runs `rm -rf -- "${dir:?}"` on a quoted, spelled-out absolute path, and a worktree goes with `git worktree remove`, never `rm` (`docs/notes/test-harness/run-and-helpers.md`).

**Keep docs current in the same change**: the `docs/user/` page for the area (user-facing behavior; README.md only for the overview, quick start and index), the module's notes file (implementation details, and its "Must not break" list), this file (rules, the command table, the module table) and `docs/status.md`.

### CRITICAL: keep Lua and the engine in sync

- A new or changed `addCommand` needs: matching `engine.*` calls (same count and types; SC type codes i/f/s), the table row above, and the engine stub picks it up from the SC source.
- A new SynthDef argument the user controls needs its type record's default, `param_order` place and spec and the exact case-sensitive name; a grain param is a record's `grain_keys` entry.
- Lua defaults are what the engine plays (`S.lib.engine_sync.start_voice` sends them at every start). SynthDef defaults for the filter and delay must equal the Lua param defaults, because the script never bangs its params.
- New voice-level controls that a buffer or input grain synth also needs belong in `voiceControls` / `grainControls` and `controlNameSets` (see Audio Sources in `docs/notes/engine/grains.md`).

### IMPORTANT: update the UI with every feature (128×64 screen)

Details: the UI core's notes (`docs/notes/lua/ui-core.md`, an index of docs/notes/lua/ui/) and each page's `docs/notes/lua/pages/<page>.md`.
- **Pages**: one record per page file at `S.registry.pages[UI_PAGES.index.<PAGE>]`; only `lib/arc/<page>.lua` sets its four arc fields. Find a page by index, never by its title; change pages only through `S.lib.ui_keys.set_ui_page`, never by setting `S.ui_page`; change a page's draw or hints, never `redraw()` (whose one other dispatch is the modal owner, `S.lib.ui_modal.push`). `docs/notes/lua/ui/pages-and-dispatch.md`.
- **ALT** is K1 held, the only way into ALT. Every ALT+K2/ALT+K3 action goes through `alt_action(page, n)`, never `alt_key` directly; a key pressed with ALT releases through `alt_key_release`, never `key_release`; a release acts only on the page it went down on. Release-time exceptions (`S.lib.ui_alt.k2_up`, BUFFER, SCENES): `docs/notes/lua/ui/alt-and-keys.md`.
- **Encoder and ring changes** never call `params:delta`: a page's `enc` calls `enc_param_delta(n, id, d)`, rings `arc_sweep_param` or `delta_with_detent`, a binary VOICE row `set_binary_param`. Fine adjustment is ALT+E3 only; a range through 0 lands and holds on 0 (`docs/notes/lua/ui/detents-and-fine.md`).
- **Redraws**: when state the screen or arc shows changes, call `request_redraw()` (`S.lib.ui_frame.request_screen_redraw()` for a frequent change no arc ring shows); never call `redraw()` or `arc_redraw()` from script code, nor `request_redraw()` from a page's `draw()`. Grid redraws stay direct (`grid_redraw()`) (`docs/notes/lua/ui/redraws.md`).
- **Header and hints**: `redraw()` draws the header (y=8, `draw_header()`, positions in `S.constants.HEADER`) and the hint row (y=62); a page never calls `draw_hints`. Transient messages go through `S.lib.ui_flash`, never a page's own flash clock. Indicators use `[BRACKETS]` (`docs/notes/lua/ui/header-and-flashes.md`; MAIN's columns: `docs/notes/lua/pages/main.md`).
- **Cursors other modules move** go through their owner: the VOICE cursor through `S.lib.ui_cursors` (`sync`, `place`, `move`; never `clamp_all()` alone or a bare assignment), the SCENES cursor through `S.lib.pages_scenes.move_cursor` (`docs/notes/lua/pages/scenes.md`), row pages through `S.lib.ui_field_list`. A ring never reaches into a page's state (`docs/notes/lua/ui/field-list-and-cursors.md`).
- A new voice type is a `lib/types/<key>.lua` record (`S.register_voice_type`: keys, specs, `main`, `note_main`, envelope) and a def appended to `voiceTypeDefs` and `noteMainRanges` (`docs/notes/lua/types.md`); `list_name` is at most 5 characters.
- The layout tests check every page for overlapping strings, text off-screen, the hint row and the MAIN divider; keep them passing. They miss strings crowding on nearby baselines and text over a rect or line: look at the page renders after a layout change (`docs/notes/lua/ui/layout-and-renders.md`).
- Before finishing, check that new values are visible with units, hints match the keys, all 7 voices fit, and nothing leaves 128×64.

### CRITICAL: keep grid and arc in step with the code

Details: `docs/notes/lua/grid-core.md`, each layout's `docs/notes/lua/grid/layout_<size>.md`, `docs/notes/lua/sequencer.md`, `docs/notes/lua/arc-core.md` and `docs/notes/lua/arc-pages.md`.
- Grid pages are one file each (`lib/grid/pages/<page>.lua`), registered with `S.register_grid_page` and written in pane coordinates (x 1-16, lines 1-7; a line is a voice on patterns, sources, positions and voices); the four layout files only arrange panes (`S.lib.grid_pane.arrange`), picked by the exact `cols`/`rows` in `grid_layout()`. Patterns are `S.patterns[voice][step]`. Anything the grid shows calls `grid_redraw()` when it changes, wherever it changes (cheap without a grid). `docs/notes/lua/grid/pane.md`
- Grid state is per port and pane (`page(port, pane)`, `any_page(n)`, `S.grid_held[port]`, `port_state(port)`): no page names a physical key or keeps state in a local or on `S`; a page change ends only its pane's keys, never a strip's. Pattern keys go through `pane.step_key`, delayed key actions through `on_hold`, a whole-pattern replacement through `S.lib.sequencer.replace_pattern` (`docs/notes/lua/grid-core.md`).
- The position page (page 5, `POSITION_PAGE` in `lib/playheads.lua`) repaints from the playheads' 15 Hz clock when `S.lib.positions.display_signature()` changes; param actions never redraw it (`docs/notes/lua/playheads.md`).
- A fader line is a page's `faders(pane)` entry, set and drawn by the pane engine alone (its keys, eight on a 64's half, upward on the 128v) and followed by the drift tick; the faders page shows `fader_param_ids`. Review whether a feature needs a key on a grid page.
- Arc: review whether new params belong on a page's rings (set only in `lib/arc/<page>.lua`). Ring feedback uses the param specs' ranges (`param_fraction`).
- Everything must degrade gracefully when no grid, arc or MIDI device is connected. Update `docs/user/grid.md`, the page's `docs/user/grid/pages/<page>.md` or the layout's `docs/user/grid/<size>.md`, `docs/user/arc.md` and the matching notes file with new patterns.

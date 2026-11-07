# CLAUDE.md

This file gives Claude Code (claude.ai/code) guidance for working in this repository. It is an index: the rules every change needs, the engine command interface and how to run the checks. Each module's details are in its own notes file (see the module table): read that file before changing the module.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It has seven synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring), each with its own granular processor. Any voice's grain stage can read one of eight stereo sample buffers or the live input instead of its synth. A filter, delay and reverb, three global LFOs, MIDI input, scenes, an eight-page screen UI (VOICE, SEQ and SCENES are placeholders while 3.1 is built), grid and arc complete it. Version 3.0 added the buffers and live input, the filter and delay, grain envelopes and triggered grains, the LFOs, MIDI and the paged screen. The current release is 3.0.2 (see CHANGELOG.md).

**Where things are documented:**
- `docs/status.md`: **read first.** It lists open items (with GitHub issues), the decisions taken during development (each with what it costs if wrong) and how to run the checks. Update it at the end of each piece of work.
- The Lua notes, one file per module under docs/notes/lua/ (the module table below names each). Each file opens with "Must not break", then what the module owns and how it works. `docs/notes/lua.md` only maps the old sections to the new files.
- `docs/notes/engine.md`: the engine. Signal flow, cross-modulation, `voiceOn` sync, retrigger and accent, pitchbend, the grain/envelope/mode params, audio sources (buffers, input, mirror, replace-never-stack, kill fade), buffer commands and file writes, SynthDefs, buses, node ordering, synth lifecycle. It splits per module with the engine in 3.2.
- `README.md`: a short overview, quick start and index of the user documentation, which is one page per area under docs/user/ (`docs/user/controls.md`, `docs/user/grid.md`, `docs/user/arc.md`, `docs/user/params.md`, ...). `CHANGELOG.md`: per-release changes.
- `docs/design/3.0-design.md`: the 3.0 design, still the reference for behavior. Where the code differs from it, CHANGELOG.md's 3.0 "Deviations from the design" and later entries say how. `docs/design/3.1-design.md` is the 3.1 design, with its work packages (§9).

## Architecture

The project is written in two languages that must stay in sync:
1. **`strata.lua` and its `lib/*.lua` modules** (the norns script): UI, params, encoders/keys, grid, arc, MIDI and LFOs. They control the engine through `engine.*` commands.
2. **`lib/Engine_Strata.sc`** (the SuperCollider engine): all synthesis and audio processing. It exposes commands with `this.addCommand()`.

```
Voice Synth → Voice Bus → Granular Processor → Main Bus → Filter → Delay → Reverb → Master (drift/limiter/saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation, 3 slots per voice)

Buffer source:  Buffer pair (L/R) → strataGrainBuf → Main Bus (and mirrored to the Voice Bus → Mod Synth)
Input source:   SoundIn → strataInput → Input Bus → strataGrain → Main Bus (and mirrored to the Voice Bus → Mod Synth)
```

### Modules, notes and tests

In include order. Unit test files are under test/unit/ (one per module).

| Module | S.lib name | Notes | Unit tests |
|--------|--------------|-------|------------|
| `strata.lua` (entry points) | | `docs/notes/lua/state-and-voices.md` | strata_test.lua, structure_test.lua |
| `lib/state.lua`, `lib/constants.lua` | S itself, S.constants | `docs/notes/lua/state-and-voices.md` | structure_test.lua |
| `lib/voices.lua` | `voices` | `docs/notes/lua/state-and-voices.md` | voices_test.lua |
| `lib/ui/frame.lua` | `ui_frame` | `docs/notes/lua/ui-and-pages.md` | ui_test.lua |
| `lib/engine_sync.lua` | `engine_sync` | `docs/notes/lua/engine-sync.md` | engine_sync_test.lua |
| `lib/buffers.lua` | `buffers` | `docs/notes/lua/buffers.md` | buffers_test.lua |
| `lib/lfos.lua` | `lfos` | `docs/notes/lua/lfos.md` | lfos_test.lua |
| `lib/mutation.lua` | `mutation` | `docs/notes/lua/mutation.md` | mutation_test.lua |
| `lib/scenes.lua` | `scenes` | `docs/notes/lua/scenes.md` | scenes_test.lua |
| `lib/midi_in.lua` | `midi_in` | `docs/notes/lua/midi.md` | midi_in_test.lua |
| `lib/params_setup.lua` | `params_setup` | `docs/notes/lua/params.md` | params_setup_test.lua |
| `lib/ui/params.lua`, `lib/ui/header.lua`, `lib/ui/text.lua`, `lib/ui/keys.lua`, `lib/ui/menu_watch.lua` | `ui_params`, `ui_header`, `ui_text`, `ui_keys`, `ui_menu_watch` | `docs/notes/lua/ui-and-pages.md` | ui_test.lua |
| `lib/ui/voice_rows.lua`, `lib/ui/cursors.lua` | `ui_voice_rows`, `ui_cursors` | `docs/notes/lua/ui-and-pages.md` | ui_cursors_test.lua |
| `lib/ui/alt.lua` | `ui_alt` | `docs/notes/lua/ui-and-pages.md` | ui_alt_test.lua |
| `lib/ui/detent.lua` | `ui_detent` | `docs/notes/lua/ui-and-pages.md` | ui_detent_test.lua |
| `lib/pages/main.lua`, `lib/pages/voice.lua`, `lib/pages/seq.lua`, `lib/pages/fx.lua`, `lib/pages/lfo.lua`, `lib/pages/buffer.lua`, `lib/pages/scenes.lua`, `lib/pages/setup.lua` | `pages_main`, `pages_voice`, `pages_seq`, `pages_fx`, `pages_lfo`, `pages_buffer`, `pages_scenes`, `pages_setup` | `docs/notes/lua/ui-and-pages.md` | pages_test.lua, ui_pages_test.lua |
| `lib/arc/core.lua`, `lib/arc/main.lua`, `lib/arc/voice.lua`, `lib/arc/seq.lua`, `lib/arc/fx.lua`, `lib/arc/lfo.lua`, `lib/arc/buffer.lua`, `lib/arc/scenes.lua` | `arc_core`, `arc_main`, `arc_voice`, `arc_seq`, `arc_fx`, `arc_lfo`, `arc_buffer`, `arc_scenes` | `docs/notes/lua/arc.md` | arc_test.lua |
| `lib/grid/core.lua`, `lib/grid/faders.lua`, `lib/grid/layout_256.lua`, `lib/grid/layout_128h.lua`, `lib/grid/layout_128v.lua`, `lib/grid/layout_64.lua` | `grid_core`, `grid_faders`, `grid_layout_256`, `grid_layout_128h`, `grid_layout_128v`, `grid_layout_64` | `docs/notes/lua/grid-and-sequencer.md` | grid_test.lua |
| `lib/sequencer.lua` | `sequencer` | `docs/notes/lua/grid-and-sequencer.md` | sequencer_test.lua |
| `lib/Engine_Strata.sc` | | `docs/notes/engine.md` | `test/engine_check.scd` (the engine check) |
| the test harness (`test/norns_stubs.lua`, `test/sync_check.lua`, ...) | | `docs/notes/lua/test-harness.md` | stubs_test.lua, docs_test.lua |

The release history and future ideas are in `docs/notes/lua/version-history.md`.

### Lua modules and `S`

`strata.lua` holds only the entry points: the shared table `S`, one `include("lib/<path>")` per module in dependency order, `init`, `redraw`, `enc`, `key`, `cleanup`, and the start steps only the script can own (init's start-up clock, `STARTUP` and `cancel_startup_clock`, and E1's settings). Everything else is in `lib/`.
- **`S`** (`lib/state.lua`: `local S = include("lib/state")()`) is the table the script and its modules share. Each call builds a fresh one, so a script reload keeps nothing from the previous run. State that more than one module uses is a field of `S` under its plain name (`S.voices`, `S.scenes`, `S.ui_page`, `S.engine_senders`, ...); state only one module uses stays local to it. `S.constants` is `lib/constants.lua`, a plain table.
- **Includes**: only `strata.lua` calls `include`, once per module, always as `include("lib/<path>")` (never `"strata/lib/..."`: the install folder may have another name). norns' `include` is `dofile`, so a second include would make a second copy with separate state. A test checks all three.
- **A module** is a constructor, `return function(S) local M = {} ... return M end`, ending with exactly `  return M` and `end` (the locals probe relies on it). Its table is `S.lib.<name>`: `S.lib.scenes` for `lib/scenes.lua`, `S.lib.<dir>_<basename>` in a subfolder (`S.lib.ui_keys`, `S.lib.grid_layout_256`). A local function another module calls becomes a field of that table (`S.lib.ui_text.fit_text`). Functions that were global stay global, defined in their module (`MODULE_HOMES` in the tests says where). Aliasing constants at the top of a constructor (`local NUM_VOICES = S.constants.NUM_VOICES`) is fine.
- **Registries** (`S.registry`, filled as the modules load): `pages` (one record per screen page), `params` (init runs each record's `add`, in PARAMS menu order), `grid_layouts` (`{key, redraw}` per grid size), `start` (init runs each step by order after the params) and `cleanup`. "Working in parallel" below says how to add to each.
- Tests reach script state with `local_value(name)` and `find_upvalue(name)`: a field of `S`, then of `S.constants`, then an upvalue of a global function.

### Lua ↔ SuperCollider Communication

**IMPORTANT**: this table is the engine command interface. The tests require exactly one row per engine `addCommand`, with the same signature and argument count. Keep the row format `` | `engine.<name>(<args>)` | `"<sig>"` | purpose | `` and update the table in the same commit as the engine. No `engine.<name>(` mentioned in this file, README.md, `docs/status.md` or `docs/notes/` may name a command the engine no longer has. Behavior details are in `docs/notes/engine.md`.

| Lua Command | SC Signature | Purpose |
|-------------|--------------|---------|
| `engine.voiceOn(voice, freq, amp, pan, grainSize, grainDensity, pitchShift)` | `"iffffff"` | Start a voice (resets `bend` to 1). Never stacks: synths still running or releasing are re-gated |
| `engine.voiceOff(voice)` | `"i"` | Stop a voice (release envelope) |
| `engine.retrigger(voice, velocity)` | `"if"` | Accent a running voice at velocity 0-1 (Karplus re-plucks; one grain in triggered mode). Creates no nodes |
| `engine.setVoiceParam(voice, param, value)` | `"isf"` | Set a synthesis param, or `bend` (MIDI pitchbend ratio) |
| `engine.setGrainParam(voice, param, value)` | `"isf"` | Set a grain param (`envShape` index, `grainMode` 0 continuous / 1 triggered, `bufPos`, ...) |
| `engine.setMasterDrift(amount)` | `"f"` | Global tape drift |
| `engine.setReverb(mix, size, damp)` | `"fff"` | Reverb mix, size, damping |
| `engine.setFilter(freq, res, type, mix)` | `"ffif"` | Master filter: 20-20000 Hz, res 0-1, type 0 LP / 1 HP / 2 BP (20 ms crossfade), mix 0 = bypass |
| `engine.setDelay(time, feedback, mix)` | `"fff"` | Master delay: 0.01-2 s, feedback 0-0.95, mix 0 = dry |
| `engine.setModSource(voice, slot, sourceVoice)` | `"iii"` | Crossmod source for slot 1-3 (-1 = none → `silentBus`, 0-6 = voice). The three crossmod commands ignore any other slot |
| `engine.setModAmpAmt(voice, slot, amount)` | `"iif"` | Crossmod amplitude depth (-2 to 2) |
| `engine.setModFreqAmt(voice, slot, amount)` | `"iif"` | Crossmod frequency depth (-2 to 2) |
| `engine.setModSpeed(voice, speed)` | `"if"` | Mod signal LFO speed (0.1-50), kept per voice for restarted mod synths |
| `engine.setGrainSource(voice, source)` | `"ii"` | 0 = synth, 1-8 = buffer slot, 9 = input. A running voice's grain synth is replaced (never stacked); a stopped voice's choice is recorded. Same source = no-op |
| `engine.loadBuffer(slot, path)` | `"is"` | Read a file into slot 0-7 (mono fills both sides): at most `bufferSeconds` at the server rate (a 96 kHz file keeps 8 s on a 48 kHz server). Voices reading the slot fade first. A missing, unreadable, empty or damaged file (checked by decoding it) leaves the slot unchanged but cancels a recording in it; a server read that fails anyway (the file vanished) leaves it empty. Both are reported by the `bufferLoadFailed` poll |
| `engine.recordBuffer(slot, seconds, level)` | `"iff"` | Record input × level into slot 0-7 (max 16 s). On completion writes the scratch take `buf<n>.wav` |
| `engine.clearBuffer(slot)` | `"i"` | Zero slot 0-7 (cancels a recording) |
| `engine.stopRecord(slot)` | `"i"` | End a recording early and keep what was captured (as a completed take). No-op if the slot is not recording |
| `engine.saveBuffer(slot, path)` | `"is"` | Write the slot's valid region as a stereo 16-bit WAV (creates the directory). Samples beyond ±1 clip symmetrically |

**Poll `bufferState`** (engine → Lua): matron's polls carry one float, so each message carries **one** slot as `slot_index * 100 + seconds` (`BUFFER_STATE_STRIDE` = 100, 0-based slot, seconds ≤ 16). It sends one slot every 0.25 s, in turn, so a full cycle of the eight slots takes 2 s, and every change is also sent at once. A slot that is recording reads 0 s.

**Poll `bufferLoadFailed`** (engine → Lua, not periodic): one message per failed load (a missing, unreadable, unsupported, empty or damaged file, at once; a server read that fails, after the fade and the read), whether or not the slot held audio, as `(load_number * 2 + emptied) * 8 + slot_index` (`NUM_BUFFERS` = 8, 0-based slot; `load_number` counts that slot's `loadBuffer` commands from 1, in the engine and in `load_buffer` alike; `emptied` = 1 when the failed server read left the slot zeroed). Lua's `buffer_load_failed` undoes exactly that load (its previous name, path and file param come back, or the slot shows empty) and never a later load, clear or recording, in whatever order the reports arrive.

**Index conversion**: voices are 0-indexed in SC and 1-indexed in Lua, so always pass `voice_idx - 1`. Mod sources go through `engine_mod_source()` (Lua 0 = none / 1-7 → SC -1 / 0-6).

**The `voices` table is the only source of values.** The engine holds no per-voice defaults. `toggle_voice` calls `engine.voiceOn` and then `sync_voice_to_engine`, which sends `setGrainSource` first, then every synth, grain and crossmod value. Param actions reach the engine only while a voice is active. The `v<i>_source` action is the exception: it also reaches stopped voices.

### Invariants that are easy to break

The engine's (details in `docs/notes/engine.md`):
- **Pattern steps and MIDI notes never create nodes.** They call `retrigger`. Velocity only scales the accent envelope's `levelScale` (sampled at trigger time), never a running signal. The engine check asserts that in every voice and grain SynthDef `velocity` feeds only `EnvGen` `levelScale` inputs; the one allowance is `\strataKarplus`, where it may multiply a `T2A` of the `t_trig` control (a single-sample pluck impulse), and that product may reach only the pluck excitation (a `Decay` input, the `Pluck` trigger). Bent copies compiled in the check must fail it.
- **Replace, never stack.** A source switch replaces the grain synth. Earlier fading synths are cut with `cutSynth` (the `kill` fade), never a second `release` (EnvGen ignores it). New grain synths are placed with `startPlacedGrainSynth`, never relative to a releasing synth.
- **`openedGate(gate)`** wraps every ASR gate, so a synth gated off in its first block still starts and frees. Never use `gate.max(...)`: it breaks forced releases.
- **Silent bus**: unrouted mod slots read `silentBus`, never control bus 0 (norns allocates the input follower there).
- **Limiter before the tanh saturator** in `\strataMaster`. The engine check asserts the order.
- **Buffer and input sources have no voice synth.** Their grain synth mirrors to `granBuses[i]` (`mirrorLevel` 1) so crossmod keeps working. The synth-source grain synth must keep `mirrorLevel` 0 (it reads that bus, so mirroring would feed back) and `pan` 0 (the voice synth already pans); buffer and input grain synths take the voice's `pan` (`panBalance`).
- **Buffer memory**: 8 × 2 mono buffers of 16 s (≈ 49 MB). Never allocate longer ones. Bufnums never change.
- **Real-time memory**: norns' scsynth pool is 8192 KB. The grain `PitchShift` window is the fixed `pitchShiftWindow` (0.1 s) and every `GrainIn`/`GrainBuf` uses `maxGrains` (128); never size a delay line or table from a control. A source switch frees at once any synth of that voice still in its kill fade (`freeCuttingSynths`), and so does a `voiceOn` that meets releasing synths built for another source (`gateVoice` hands them to `fadingSynths`, never leaves them releasing beside the new ones), so a voice never holds more than its live synths, one fading and one cutting set, however fast switches, stops and starts arrive. A scene recall stops the voices it stops before setting their sources. The worst case uses about 6.9 MB and the engine check requires 1 MB left, spaced, in a burst and for fast A -> B -> A -> C recalls (see Real-time memory in `docs/notes/engine.md`).
- **`slotChanges[i]`** guards late replies (load completion, `stopRecord` frame count) and the fade wait: a clear or load sent later always wins. A `bufferLoadFailed` report names its load's number, so it too never undoes a later load, clear or recording.
- **Fade before zeroing**: load, record and clear set the slot's frames to 0 first (`hasAudio` fades the voices) and zero or overwrite its buffers through `afterSlotFade` (`bufferFadeWait`, 60 ms, when a grain synth reads the slot). Never zero a slot directly. That covers every `\strataGrainBuf` until it frees, releasing and fading ones too (`grainSlots`, `slotGrainSynths`): those only ever get `bufFrames 0`. `bufRateScale` is sent only with a valid length (`slotLengthPairs`), never to grains fading out.
- **Messages to synths that can end on their own** (releasing, fading or cutting synths; a voice's live synths in `setSynth` with a voice, grain or mod key, `releaseVoice` and switches; record synths) go through `sendToSynth` (a bundle with `/error -1`), never `synth.set`/`release`/`free`/`moveBefore` directly: the synth may have freed a moment ago, and the server's `FAILURE ... Node not found` line fails the engine check. The effects chain's synths (`effectKeys`: filter, delay, reverb, master) never end on their own, so `setSynth` sends to them plainly: a failure there is a real bug and must stay reported.
- **NaN guards**: `\strataFilter` (before the effects) and `\strataMod` (input and output, so a voice that blows up never spreads through crossmod) replace bad values with `zeroBadValues`.
- **File writes** go to a `<path>.<instanceTag>-<generation>.part` file and are renamed into place. Never open the final path for writing. `deleteStaleParts` deletes only `.part` files and `writeSlot`'s temporary float files older than `stalePartAge`.
- **`\strataFilter`**: never compare a UGen with `==` (that is object identity); use `BinaryOpUGen('==', ...)`.

The Lua side's, across modules (each module's own list opens its notes file):
- **Param → engine** goes through `send_param_to_engine(id, value)` and an `S.engine_senders[id]` entry (this adds the LFO offsets). Never call `engine.*` from a control param's action directly. LFOs modulate around the stored value and never `params:set` their destination.
- **Scenes**: a new captured field needs `validate_scene` coverage and a migration default (`SCENE_GLOBAL_PARAMS.default`, `VOICE_SCENE_DEFAULTS` or `SCENE_BLOCK_DEFAULTS`). Discrete keys (`DISCRETE_GRAIN_KEYS`, source, mod sources) switch at the end of a transition, never crossfade. A recall sends one full sync per running voice whose source changed, after its params (`S.scene_recall_in_progress`).
- **Source tests**: use `voice_uses_synth(i)` / `voice_uses_buffer(i)`. Never use `not voice_uses_synth` (that includes input).
- **Grid, arc and MIDI handlers live on the vport only** (`grid.connect(port)`, `arc.connect`, `midi.connect`). Never store or attach to the raw device passed to `grid.add`.
- **Arc rings** sweep their range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512) ticks through `arc_sweep_param` and are drawn through `arc_ring_fill` from `param_fraction`, or `arc_ring_fill_bipolar` for a range through 0 (`arc_ring_fill_param` picks). Strata follows one arc. The exceptions and details are in `docs/notes/lua/arc.md`.

## Working in parallel

Several pull requests are built at once, often by agents. The rule: a feature lives in files that only that feature's work edits, apart from one-line registrations.
- **One worktree per pull request.** Branch from an up-to-date `main` in a worktree of its own; never share a checkout between two pieces of work. Engine checks in different worktrees can run at once on different `$STRATA_SC_PORT` ports (Development & Testing).
- **Edit only the files your package owns.** A release's design lists its work packages and the files each owns (for 3.1, §9 of `docs/design/3.1-design.md`). Besides those, a package edits only registration lines (below), and its own notes file, unit test file and `docs/user/` page. Need a change in a file another package owns? Ask for it, or make it a separate pull request.
- **Where things live**: a module's table is `S.lib.<name>` (top-level `lib/` files) or `S.lib.<dir>_<basename>` (subfolders); shared state is on `S` under its plain name; the registries are `S.registry.pages`, `S.registry.params`, `S.registry.start`, `S.registry.cleanup` and `S.registry.grid_layouts`.
- **Registering a page**: a new `lib/pages/<name>.lua` creates its record at `S.registry.pages[UI_PAGES.index.<NAME>]` and sets every field but the four arc fields. Add the name to `UI_PAGES` in `lib/constants.lua` (one line; `NUM_UI_PAGES` is `#UI_PAGES` and `UI_PAGES.index` follows) and its `include` to `strata.lua` among the page includes (one line). Its rings, if any, go in a `lib/arc/<name>.lua`, included after every page file, that sets only `arc_delta`, `arc_redraw`, `arc_alt_delta` and `arc_alt_redraw` on the record. So a page package and the arc package never edit the same file. All eight 3.1 pages already have both files (VOICE, SEQ and SCENES as stubs): filling them in adds no include.
- **Registering a param group**: one `register_params(name, add)` call in `lib/params_setup.lua`, at its place in the PARAMS menu (the registration order is the menu order). Keep the group's body in the owning module where you can, and call it from `add` (as the "lfos" record calls `add_lfo_params`).
- **Registering a start step**: `S.register_start(S.constants.START_ORDER.<step>, fn)` in the module that owns the resource, next to its cleanup step, and one line in `START_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (spaced by 10; two steps never share one). init runs the steps after the params are added, so a step can read them. `init` itself is never edited. Add the step's effects to `start_steps()` in `test/unit/structure_test.lua`.
- **Registering a cleanup step**: `S.register_cleanup(S.constants.CLEANUP_ORDER.<step>, fn)` in the module that starts the resource, and one line in `CLEANUP_ORDER` (`lib/constants.lua`) at a free order at its place in the sequence (orders are spaced by 10; two steps never share one). `cleanup()` itself is never edited.
- **Registering a grid layout**: a `lib/grid/layout_<name>.lua` sets `S.registry.grid_layouts["<name>"] = {key = ..., redraw = ...}`, plus one `include` line in `strata.lua` and the size match in `grid_layout()` (`lib/grid/core.lua`).
- **On a conflict in a registration line** (an include, a `UI_PAGES` entry, a `START_ORDER` or `CLEANUP_ORDER` entry, a `register_params` call, a module table row in this file): keep both lines, in the order the sequence needs, and rerun the checks. Two `START_ORDER` or `CLEANUP_ORDER` entries on the same number: give the later one a free number.
- **Shared files** (CHANGELOG.md, `docs/status.md`, this file, README.md): edit them only where your package needs to. A feature pull request never edits CHANGELOG.md.
- **Changelog**: every pull request adds a changelog fragment `changes/<branch-name>.md`; see `changes/README.md`. The release pull request merges the fragments into CHANGELOG.md.

## Development & Testing

**On norns:** copy the project to `~/dust/code/`, then restart norns or run `;restart` in maiden. SuperCollider changes need a script restart. Watch the maiden console for errors.

**Off-device checks** (run from the repo root before committing; CI runs all three, see `docs/status.md`):
- `lua test/run.lua` and `luajit test/run.lua`: the behavior tests against norns stubs (`test/norns_stubs.lua`). Tests live in test/unit/<module>_test.lua (one file per module, discovered automatically). `lua test/run.lua` runs all (as CI does); `lua test/run.lua <filter>` runs the unit files whose name contains `<filter>` (`lua test/run.lua scenes`). Run your module's file while you work and the whole suite before pushing.
  - The engine stub rejects any `engine.*` call whose name, argument count or types do not match the engine's `addCommand` signatures, whose index or enumerated arguments are out of the engine's range, or whose `setVoiceParam`/`setGrainParam` name is not a control of the engine's SynthDefs. Every parser of the engine source skips `//` and `/* */` comments.
  - The run also includes the sync check, the CLAUDE.md table check, a docs check over the maintained docs (this file, README.md, `docs/status.md`, and every `.md` under docs/notes/, recursively, and docs/user/: no `engine.<name>(` names a missing command, every path under docs/, test/, .github/ or lib/ named in backticks exists, every relative Markdown link resolves from the doc's own folder, and every docs/notes/lua/ file's first heading is `## Must not break`), a check that every changelog fragment in changes/ has an Added, Changed or Fixed heading with a bullet, and checks that the FX SynthDefs' defaults equal the Lua param defaults and that `numVoices`, `numBuffers`, `bufferSeconds`, `bufferStateStride` and `numModSlots` equal the script's constants (`lib/constants.lua`; `BUFFER_STATE_STRIDE` is in `lib/buffers.lua`).
  - Module safety nets: the global-reference and duplicate-global checks (Lua 5.3 with `luac` or `luac5.3` on PATH; LuaJIT skips them) and the locals probe (30 free locals in each file's main chunk and each constructor). Tests also check the includes, that a second load shares no state with the first, the constructor shape, and `MODULE_HOMES`. Details: `docs/notes/lua/test-harness.md`.
- US spelling is enforced by a test (`text uses US spelling` in `test/unit/docs_test.lua`; extend its word list).
- `lua test/sync_check.lua`: every `engine.<name>(...)` call has a matching `addCommand` with the same argument count, and every command is used. Call engine commands only as `engine.<name>(...)`: any other use of `engine` (`engine[name](...)`, `local f = engine.voiceOn`, `local e = engine`) fails the check, which cannot see what it calls.
- `test/run_engine_check.sh [path/to/norns]`: compiles the engine against norns `sc/core` (default `~/src/norns`, or `$NORNS_DIR`) and runs `test/engine_check.scd` on a silent local scsynth. It needs SuperCollider (`$SCLANG` overrides the path). Each run boots scsynth on `$STRATA_SC_PORT` (default 57110); runs on different ports (avoid 57120 and the few above it, used by sclang itself) can overlap; runs on the same port collide. It stops sclang after `$ENGINE_CHECK_TIMEOUT` s (570) and at once on a compile error, so a broken check never hangs. Besides a failed check it fails on any `ERROR`, `FAILURE`, `alloc failed`, `Too many grains` or `Strata invariant broken` line.
- Add a test to the unit file of the module you change, for every behavior change. Script state is reached through `local_value()`/`find_upvalue()` (fields of `S`, then `S.constants`, then upvalues), so a name the tests use must stay a field of `S` or `S.constants` under that name.
- The stubs mirror the real norns libraries (`~/src/norns/lua`): check behavior there before changing them. `param.t` holds numeric type codes (`params.tOPTION`, ...), so never compare it with a string (a test enforces this). The stubbed APIs and test helpers (`context.polls.fire`, `context.midi.plug`, `context.set_time`, `context.encoders.deliver`, ...) are listed in `docs/notes/lua/test-harness.md`.
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file: norns compiles every `.sc` under `~/dust`.

**Common norns pitfalls:**
- `UI.List` has no `set_items()`: recreate the list. `UI.List.new(x, y, index, items)` needs every argument.
- `clock.sleep()` works only inside `clock.run(...)`. Never call it in `init()`.
- Param IDs must be unique, and norns has built-ins such as `reverb`. Use prefixed ids (`strata_fx`, ...).
- A group's size `n` must equal the number of params that follow it. Groups cannot nest. The stub errors when a group gets fewer than `n` params before the next group or the end of the list, or when the param after its last one is not a separator or a group.

## Code Style Guidelines

**Named constants, never magic numbers.** They live in `lib/constants.lua` (`S.constants`, aliased as locals at the top of each module that uses them): `NUM_VOICES` (7), `NUM_SCENES` (8), `PATTERN_LENGTH` (16), `SCENE_DATA_VERSION` (2), `NUM_MOD_SLOTS` (3), `NUM_UI_PAGES` (8, `#UI_PAGES`), `MAX_STEP_LEVEL` (15), `NUM_BUFFERS` (8), `BUFFER_SECONDS` (16), `BUFFER_DATA_VERSION` (1), `NUM_LFOS` (3). The engine mirrors them as `numVoices`, `numBuffers`, `bufferSeconds` and `numModSlots`. Never hardcode 7, 8 or 16 in voice, scene, pattern or buffer code (bare numbers in grid code are coordinates and LED levels).

**Lua's 200-local limit applies to each function, checked by a test**: the locals probe measures the free locals at the end of each file's main chunk and of each module's constructor function, and fails when any has fewer than 30 (`strata.lua`'s main chunk uses 5). Group a feature's constants in one table (as `LFO_PAGE`, `GRID_LAYOUT`, `BUFFER_PAGE`, `FX_PAGE`, `BUFFER_SETTLE` do) rather than adding many `local`s, and split a module that runs short.

**Descriptive names**: `selected_voice`, not `sv`; `master_density`, not `md`.

**Bounds-check every index** (voice 1..`NUM_VOICES`, scene, step, slot, grid coordinates) before indexing, so tables never grow by accident. **Clean up** every metro, clock, poll and device handler on exit: the module that owns it registers a step with `S.register_cleanup` at its place in `S.constants.CLEANUP_ORDER` (never code in `cleanup()` itself; the sequence is in `docs/notes/lua/state-and-voices.md`). Cancel an existing clock before starting its replacement.

**Keep docs current in the same change**: the `docs/user/` page for the area (user-facing behavior; README.md only for the overview, quick start and index), the module's notes file (implementation details, and its "Must not break" list), this file (rules, the command table, the module table) and `docs/status.md`.

### CRITICAL: keep Lua and the engine in sync

- A new or changed `addCommand` needs: matching `engine.*` calls (same count and types; SC type codes i/f/s), the table row above, and the engine stub picks it up from the SC source.
- A new SynthDef argument the user controls needs: the `voices` table default, the voice's `param_order`, `add_voice_params()`, `get_param_spec()`, a sender in `S.engine_senders`, and the exact case-sensitive name. Grain params go through `setGrainParam` and `GRAIN_PARAM_IDS`.
- Lua defaults are what the engine plays (`sync_voice_to_engine` sends them). SynthDef defaults for the filter and delay must equal the Lua param defaults, because the script never bangs its params.
- New voice-level controls that a buffer or input grain synth also needs belong in `voiceControls` / `grainControls` and `controlNameSets` (see Audio Sources in `docs/notes/engine.md`).

### IMPORTANT: update the UI with every feature (128×64 screen)

Details: `docs/notes/lua/ui-and-pages.md`.
- Pages: `UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "BUFFER", "SCENES", "SETUP"}` (`UI_PAGES.index[name]` gives the index; `UI_PAGES.MAIN_PAGE` is 1). Each page file (`lib/pages/main.lua`, ...) creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]`, which `enc`, `key` and `redraw` in `strata.lua` dispatch through. Required fields: `name`, `draw()` (the page body only), `hints(alt_held)` (the hint row's text), `enc(n, d)`, `key(n)`; optional: `alt_enc`, `alt_key`, `key_release`, `alt_key_release`, `enter`, `leave` (run by `set_ui_page` on a page change), `arc_button`, `header_status`, `layout_states`. Its rings' file (`lib/arc/main.lua`, ...) sets only the arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`), which `arc_delta`/`arc_redraw` in `lib/arc/core.lua` dispatch through (a page without them, SETUP, ignores turns and leaves the rings off); the page file never sets them. `docs/notes/lua/ui-and-pages.md` describes each field. Change a page's draw or hints function (`redraw_main`, ...), never `redraw()`.
- **ALT** is K1 held (`S.alt_held`, set through `S.lib.ui_alt.set`; `lib/ui/alt.lua`). Every ALT+K2/ALT+K3 action goes through `alt_action(page, n)` (global), which runs the record's `alt_key(n)`, so the long-press fallback (`S.lib.ui_alt.long_press`, `LONG_PRESS_SECONDS` 0.6) triggers the same actions; never call `alt_key` directly. A key that went down with ALT is an ALT press (`S.key_press_alt`): its release goes to `alt_key_release`, never `key_release`, even if K1 came up first, and it never reaches `key`. With ALT held, E2/E3 go to `alt_enc(n, d)` first and on to `enc` unless it returns true; E1 ignores ALT. `forget_held_keys` clears ALT and the ALT presses.
- **Encoder and ring changes**: never call `params:delta` from an encoder or a ring. A page's `enc` calls `enc_param_delta(n, id, d)` for every param edit; rings call `arc_sweep_param` or `delta_with_detent(id, d, opts)` (`lib/ui/detent.lua`). Fine adjustment is ALT+E3 only (a control param moves `quantum / FINE_DIVISOR` of raw per detent), never ALT+E2 or the arc. Center detents: a range through 0 lands on exactly 0 when a change reaches or crosses it, whatever the delta, and holds there for `DETENT.encoder_detents` (3) detents or `DETENT.arc_ticks` (24) ticks.
- **Redraws**: when state the screen or arc shows changes, call `request_redraw()`; never call `redraw()` or `arc_redraw()` from script code. The frame clock draws whatever is dirty at `UI_PAGES.FRAMES_PER_SECOND` (15), and every param action already requests one. Grid redraws stay direct (`grid_redraw()`).
- Every page has the header at y=8 (`draw_header()`: title, `dens:`, `[M]` at x=98, scene `S1`-`S8` right-aligned at 127) and the hint row at y=62 (`redraw()` draws it with `draw_hints(record.hints(S.alt_held))`; a page never calls `draw_hints`). On MAIN the voice list (x 0-60, `UI.ScrollingList`, 4 visible rows) sits left of the divider at x=62 and the selected voice's details at x 65-127. Status indicators use `[BRACKETS]`; levels are 15 bright, 4 dim, 1-2 subtle.
- A new voice type needs a `MAIN_PARAMS` entry (E3, the MAIN display and arc ring 2 follow; `list_name` is its voice-list name, at most 5 characters) and `get_param_spec()` specs.
- The layout tests check every page for overlapping strings, text off-screen, the hint row and the list's bottom edge, and that no MAIN string crosses the divider (width estimate: `stubs.text_width`). Keep them passing.
- Before finishing, check that new values are visible with units, hints match the keys, all 7 voices fit, and nothing leaves 128×64.

### CRITICAL: keep grid and arc in step with the code

Details: `docs/notes/lua/grid-and-sequencer.md` and `docs/notes/lua/arc.md`.
- Grid layouts: `grid_key_256/128h/128v/64()` and `grid_redraw_*()`, one file per layout (`lib/grid/layout_256.lua`, ...), each registering `{key, redraw}` in `S.registry.grid_layouts`; `grid_key` and `grid_redraw` (`lib/grid/core.lua`) dispatch through it by the name `grid_layout()` picks from the exact `cols`/`rows`. The 256's faders are in `lib/grid/faders.lua`. Patterns are `S.patterns[voice][step]` (`lib/sequencer.lua`). Anything the grid shows must call `grid_redraw()` when it changes, wherever it changes (cheap without a grid).
- New params in `param_order` appear on the 256 fader page automatically (`fader_param_ids`, `set_param_from_column`, which follows the controlspec warp). Review whether a feature needs grid buttons or LED feedback on every layout.
- Arc: review whether new params belong on a page's rings (`lib/arc/main.lua`, ...: `arc_*_delta`/`arc_*_redraw`, `ARC_FX_RINGS`, `ARC_BUFFER_RINGS`). Ring feedback must use the same ranges as the param specs (`param_fraction`).
- Everything must degrade gracefully when no grid, arc or MIDI device is connected. Update `docs/user/grid.md`, `docs/user/arc.md` and the matching notes file with new patterns.

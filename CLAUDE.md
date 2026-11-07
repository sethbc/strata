# CLAUDE.md

This file gives Claude Code (claude.ai/code) guidance for working in this repository. It holds the rules and the engine interface. The detailed implementation reference is in separate files: read the section you need before changing that area.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It has seven synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring), each with its own granular processor. Any voice's grain stage can read one of eight stereo sample buffers or the live input instead of its synth. A filter, delay and reverb, three global LFOs, MIDI input, scenes, a five-page screen UI, grid and arc complete it. Version 3.0 added the buffers and live input, the filter and delay, grain envelopes and triggered grains, the LFOs, MIDI and the paged screen. The current release is 3.0.2 (see CHANGELOG.md).

**Where things are documented:**
- `docs/status.md`: **read first.** It lists open items (with GitHub issues), the decisions taken during development (each with what it costs if wrong) and how to run the checks. Update it at the end of each piece of work.
- `docs/notes/engine.md`: the engine. Signal flow, cross-modulation, `voiceOn` sync, retrigger and accent, pitchbend, the grain/envelope/mode params, audio sources (buffers, input, mirror, replace-never-stack, kill fade), buffer commands and file writes, SynthDefs, buses, node ordering, synth lifecycle.
- `docs/notes/lua.md`: the Lua side. Voice state, `send_param_to_engine`, the param system, LFOs, MIDI, mutations, scenes (transitions, migration, validation, persistence), buffers persistence, bounds checks, cleanup, grid, arc, screen pages and MAIN layout, plus the version history and future ideas.
- `README.md`: user documentation (controls, grid/arc layouts, params). `CHANGELOG.md`: per-release changes.
- `docs/design/3.0-design.md`: the 3.0 design, still the reference for behavior. Where the code differs from it, CHANGELOG.md's 3.0 "Deviations from the design" and later entries say how.

## Architecture

The project is written in two languages that must stay in sync:
1. **`strata.lua`** (the norns script): UI, params, encoders/keys, grid, arc, MIDI and LFOs. It controls the engine through `engine.*` commands.
2. **`lib/Engine_Strata.sc`** (the SuperCollider engine): all synthesis and audio processing. It exposes commands with `this.addCommand()`.

```
Voice Synth → Voice Bus → Granular Processor → Main Bus → Filter → Delay → Reverb → Master (drift/limiter/saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation, 3 slots per voice)

Buffer source:  Buffer pair (L/R) → strataGrainBuf → Main Bus (and mirrored to the Voice Bus → Mod Synth)
Input source:   SoundIn → strataInput → Input Bus → strataGrain → Main Bus (and mirrored to the Voice Bus → Mod Synth)
```

### Lua ↔ SuperCollider Communication

**IMPORTANT**: this table is the engine command interface. `test/run.lua` requires exactly one row per engine `addCommand`, with the same signature and argument count. Keep the row format `` | `engine.<name>(<args>)` | `"<sig>"` | purpose | `` and update the table in the same commit as the engine. No `engine.<name>(` mentioned in this file, README.md, `docs/status.md` or `docs/notes/` may name a command the engine no longer has. Behavior details are in `docs/notes/engine.md`.

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

### Invariants that are easy to break (details in `docs/notes/engine.md`)

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
- **Param → engine** goes through `send_param_to_engine(id, value)` and an `engine_senders[id]` entry (this adds the LFO offsets). Never call `engine.*` from a control param's action directly. LFOs modulate around the stored value and never `params:set` their destination.
- **Scenes**: a new captured field needs `validate_scene` coverage and a migration default (`SCENE_GLOBAL_PARAMS.default`, `VOICE_SCENE_DEFAULTS` or `SCENE_BLOCK_DEFAULTS`). Discrete keys (`DISCRETE_GRAIN_KEYS`, source, mod sources) switch at the end of a transition, never crossfade. A recall sends one full sync per running voice whose source changed, after its params (`scene_recall_in_progress`).
- **Source tests**: use `voice_uses_synth(i)` / `voice_uses_buffer(i)`. Never use `not voice_uses_synth` (that includes input).
- **Grid and arc handlers live on the vport only** (`grid.connect(port)`, `arc.connect`). Never store or attach to the raw device passed to `grid.add`.
- **Arc rings** sweep their range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512) ticks through `arc_sweep_param`. Never give a ring its own scale. The only exceptions are the LFO page's whole-value rings (depth at 10 ticks per percent, clocked rate at 20 ticks per rate).
- **Arc drawing**: every ring is drawn through `arc_ring_fill` from `param_fraction`, never from a hardcoded range.
- **Arc port**: Strata follows one arc, on the vport of the device (`device.port`, port 1 if unassigned; at init the first vport holding a device). While one is connected, `arc.add` of another arc is ignored and `arc.remove` disconnects only the connected one.

## Development & Testing

**On norns:** copy the project to `~/dust/code/`, then restart norns or run `;restart` in maiden. SuperCollider changes need a script restart. Watch the maiden console for errors.

**Off-device checks** (run from the repo root before committing; CI runs all three, see `docs/status.md`):
- `lua test/run.lua` and `luajit test/run.lua`: behavior tests against norns stubs (`test/norns_stubs.lua`). The engine stub rejects any `engine.*` call whose name, argument count or types do not match the engine's `addCommand` signatures, whose index or enumerated arguments are out of the engine's range, or whose `setVoiceParam`/`setGrainParam` name is not a control of the engine's SynthDefs. Every parser of the engine source skips `//` and `/* */` comments. The run also includes the sync check, the CLAUDE.md table check, a docs check (no `engine.<name>(` in this file, README.md, `docs/status.md` or `docs/notes/` names a missing command, and every path under docs/, test/ or .github/ that they name in backticks exists), and checks that the FX SynthDefs' defaults equal the Lua param defaults and that `numVoices`, `numBuffers`, `bufferSeconds`, `bufferStateStride` and `numModSlots` equal their `strata.lua` constants. Three refactor safety nets run too: the golden master (one scripted session's engine calls, screen, grid and arc frames and file writes must equal `test/fixtures/wave0_baseline.txt`; if it differs, the change altered behavior: fix the change, never the baseline), the global-reference check (under Lua 5.3, which then needs `luac` or `luac5.3` on PATH and fails without one; LuaJIT skips it: every global any Lua file reads is written by a script file or provided by the stubs) and the locals probe (each Lua file keeps 30 free locals in its main chunk and constructor; `strata.lua` 14 until Wave 0 ends).
- `lua test/sync_check.lua`: every `engine.<name>(...)` call has a matching `addCommand` with the same argument count, and every command is used. Call engine commands only as `engine.<name>(...)`: any other use of `engine` (`engine[name](...)`, `local f = engine.voiceOn`, `local e = engine`) fails the check, which cannot see what it calls.
- `test/run_engine_check.sh [path/to/norns]`: compiles the engine against norns `sc/core` (default `~/src/norns`, or `$NORNS_DIR`) and runs `test/engine_check.scd` on a silent local scsynth. It needs SuperCollider (`$SCLANG` overrides the path). Run only one at a time per machine (port 57110). It stops sclang after `$ENGINE_CHECK_TIMEOUT` s (570) and at once on a compile error, so a broken check never hangs. Besides a failed check it fails on any `ERROR`, `FAILURE`, `alloc failed`, `Too many grains` or `Strata invariant broken` line.
- Add a test to `test/run.lua` for every behavior change. Script locals are reached through `find_upvalue()`/`local_value()`.
- The stubs mirror the real norns libraries (`~/src/norns/lua`): check behavior there before changing them. `param.t` holds numeric type codes (`params.tOPTION`, ...), so never compare it with a string (a test enforces this). The stubbed APIs and test helpers (`context.polls.fire`, `context.midi.plug`, `context.set_time`, `context.encoders.deliver`, ...) are listed under "Test harness details" in `docs/notes/lua.md`.
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file: norns compiles every `.sc` under `~/dust`.

**Common norns pitfalls:**
- `UI.List` has no `set_items()`: recreate the list. `UI.List.new(x, y, index, items)` needs every argument.
- `clock.sleep()` works only inside `clock.run(...)`. Never call it in `init()`.
- Param IDs must be unique, and norns has built-ins such as `reverb`. Use prefixed ids (`strata_fx`, ...).
- A group's size `n` must equal the number of params that follow it. Groups cannot nest. The stub errors when a group gets fewer than `n` params before the next group or the end of the list, or when the param after its last one is not a separator or a group.

## Code Style Guidelines

**Named constants, never magic numbers.** They live in `lib/constants.lua` (`S.constants`, aliased as locals at the top of `strata.lua`): `NUM_VOICES` (7), `NUM_SCENES` (8), `PATTERN_LENGTH` (16), `SCENE_DATA_VERSION` (2), `NUM_MOD_SLOTS` (3), `NUM_UI_PAGES` (5), `MAX_STEP_LEVEL` (15), `NUM_BUFFERS` (8), `BUFFER_SECONDS` (16), `BUFFER_DATA_VERSION` (1), `NUM_LFOS` (3). The engine mirrors them as `numVoices`, `numBuffers`, `bufferSeconds` and `numModSlots`. Never hardcode 7, 8 or 16 in voice, scene, pattern or buffer code (bare numbers in grid code are coordinates and LED levels).

**Lua's 200-local limit**: `strata.lua`'s main chunk uses 185 locals. Group a feature's constants in one table (as `LFO_PAGE`, `GRID_LAYOUT`, `BUFFER_PAGE`, `FX_PAGE`, `BUFFER_SETTLE` do) or use global functions; never add many top-level `local`s. To measure the headroom, append `local probe1, ..., probeN` to a copy of the script and run `luac -p` on it. The harness fails with "too many local variables" when the limit is hit.

**Descriptive names**: `selected_voice`, not `sv`; `master_density`, not `md`.

**Bounds-check every index** (voice 1..`NUM_VOICES`, scene, step, slot, grid coordinates) before indexing, so tables never grow by accident. **Clean up** every metro, clock, poll and device handler in `cleanup()`, and cancel an existing clock before starting its replacement.

**Keep docs current in the same change**: README.md (user-facing behavior), this file (rules, command table) and the matching `docs/notes/` file (implementation details), plus `docs/status.md`.

### CRITICAL: keep Lua and the engine in sync

- A new or changed `addCommand` needs: matching `engine.*` calls (same count and types; SC type codes i/f/s), the table row above, and the engine stub picks it up from the SC source.
- A new SynthDef argument the user controls needs: the `voices` table default, the voice's `param_order`, `add_voice_params()`, `get_param_spec()`, a sender in `engine_senders`, and the exact case-sensitive name. Grain params go through `setGrainParam` and `GRAIN_PARAM_IDS`.
- Lua defaults are what the engine plays (`sync_voice_to_engine` sends them). SynthDef defaults for the filter and delay must equal the Lua param defaults, because the script never bangs its params.
- New voice-level controls that a buffer or input grain synth also needs belong in `voiceControls` / `grainControls` and `controlNameSets` (see Audio Sources in `docs/notes/engine.md`).

### IMPORTANT: update the UI with every feature (128×64 screen)

- Pages: `UI_PAGES = {"MAIN", "FX", "LFO", "BUFFER", "SETUP"}`, dispatched through `PAGE_DRAW`/`PAGE_ENC`/`PAGE_KEY`/`PAGE_KEY_RELEASE`, with `ARC_PAGE_DELTA`/`ARC_PAGE_REDRAW` indexed the same way. A new page adds its functions to every table, defined above them. Change a page's draw function (`redraw_main`, ...), never `redraw()`.
- **Redraws**: when state the screen or arc shows changes, call `request_redraw()`; never call `redraw()` or `arc_redraw()` from script code. The frame clock draws whatever is dirty at `UI_PAGES.FRAMES_PER_SECOND` (15), and every param action already requests one (details in `docs/notes/lua.md`, Redraws). Grid redraws stay direct (`grid_redraw()`).
- Every page has the header at y=8 (`draw_header()`: title, `dens:`, `[M]` at x=98, scene `S1`-`S8` right-aligned at 127) and the hint row at y=62 (`draw_hints()`). On MAIN the voice list (x 0-60, `UI.ScrollingList`, 4 visible rows) sits left of the divider at x=62 and the selected voice's details at x 65-127. Status indicators use `[BRACKETS]`; levels are 15 bright, 4 dim, 1-2 subtle.
- A new voice type needs a `MAIN_PARAMS` entry (E3, the MAIN display and arc ring 2 follow; `list_name` is its voice-list name, at most 5 characters) and `get_param_spec()` specs.
- `test/run.lua` checks every page for overlapping strings, text off-screen, the hint row and the list's bottom edge, and that no MAIN string crosses the divider (width estimate: `stubs.text_width`). Keep it passing.
- Before finishing, check that new values are visible with units, hints match the keys, all 7 voices fit, and nothing leaves 128×64.

### CRITICAL: keep grid and arc in step with the code

- Grid layouts: `grid_key_256/128h/128v/64()` and `grid_redraw_*()`, chosen by exact `cols`/`rows` in `grid_layout()`. Patterns are `patterns[voice][step]`. Anything the grid shows must call `grid_redraw()` when it changes, wherever it changes (cheap without a grid).
- New params in `param_order` appear on the 256 fader page automatically (`fader_param_ids`, `set_param_from_column`, which follows the controlspec warp). Review whether a feature needs grid buttons or LED feedback on every layout.
- Arc: review whether new params belong on a page's rings (`arc_*_delta`/`arc_*_redraw`, `ARC_FX_RINGS`, `ARC_BUFFER_RINGS`). Ring feedback must use the same ranges as the param specs (`param_fraction`).
- Everything must degrade gracefully when no grid, arc or MIDI device is connected. Update README's grid/arc sections and `docs/notes/lua.md` with new patterns.

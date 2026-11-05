# CLAUDE.md

This file gives Claude Code (claude.ai/code) guidance for working in this repository. It holds the rules and the engine interface. The detailed implementation reference is in separate files: read the section you need before changing that area.

## Project Overview

Strata is an ambient granular soundscape generator for monome norns. It has seven synthesis voices (Resonator, FM, Folder, Sub, Pulse, Karplus, Ring), each with its own granular processor. Any voice's grain stage can read one of eight stereo sample buffers or the live input instead of its synth. A filter, delay and reverb, three global LFOs, MIDI input, scenes, a five-page screen UI, grid and arc complete it. Version 3.0 absorbed the Confluence script's feature set (see CHANGELOG.md).

**Where things are documented:**
- `docs/superpowers/status.md`: **read first.** It lists open items (with GitHub issues), the decisions taken on Seth's behalf and how to run the checks. Update it at the end of each piece of work.
- `docs/notes/engine.md`: the engine. Signal flow, cross-modulation, `voiceOn` sync, retrigger and accent, pitchbend, the grain/envelope/mode params, audio sources (buffers, input, mirror, replace-never-stack, kill fade), buffer commands and file writes, SynthDefs, buses, node ordering, synth lifecycle.
- `docs/notes/lua.md`: the Lua side. Voice state, `send_param_to_engine`, the param system, LFOs, MIDI, mutations, scenes (transitions, migration, validation, persistence), buffers persistence, bounds checks, cleanup, grid, arc, screen pages and MAIN layout, plus the version history and future ideas.
- `README.md`: user documentation (controls, grid/arc layouts, params). `CHANGELOG.md`: per-release changes.
- `docs/superpowers/specs/2026-11-03-confluence-features-design.md`: the 3.0 design, still the reference for behaviour.

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

**IMPORTANT**: this table is the engine command interface. `test/run.lua` requires exactly one row per engine `addCommand`, with the same signature and argument count. Keep the row format `` | `engine.<name>(<args>)` | `"<sig>"` | purpose | `` and update the table in the same commit as the engine. No `engine.<name>(` mentioned in this file or in README.md may name a command the engine no longer has. Behaviour details are in `docs/notes/engine.md`.

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
| `engine.setModSource(voice, slot, sourceVoice)` | `"iii"` | Crossmod source for slot 1-3 (-1 = none → `silentBus`, 0-6 = voice) |
| `engine.setModAmpAmt(voice, slot, amount)` | `"iif"` | Crossmod amplitude depth (-2 to 2) |
| `engine.setModFreqAmt(voice, slot, amount)` | `"iif"` | Crossmod frequency depth (-2 to 2) |
| `engine.setModSpeed(voice, speed)` | `"if"` | Mod signal LFO speed (0.1-50) |
| `engine.setGrainSource(voice, source)` | `"ii"` | 0 = synth, 1-8 = buffer slot, 9 = input. A running voice's grain synth is replaced (never stacked); a stopped voice's choice is recorded. Same source = no-op |
| `engine.loadBuffer(slot, path)` | `"is"` | Read up to 16 s of a file into slot 0-7 (mono fills both sides). An unreadable file leaves the slot unchanged |
| `engine.recordBuffer(slot, seconds, level)` | `"iff"` | Record input × level into slot 0-7 (max 16 s). On completion writes the scratch take `buf<n>.wav` |
| `engine.clearBuffer(slot)` | `"i"` | Zero slot 0-7 (cancels a recording) |
| `engine.stopRecord(slot)` | `"i"` | End a recording early and keep what was captured (as a completed take). No-op if the slot is not recording |
| `engine.saveBuffer(slot, path)` | `"is"` | Write the slot's valid region as a stereo 16-bit WAV (creates the directory) |

**Poll `bufferState`** (engine → Lua): matron's polls carry one float, so each message carries **one** slot as `slot_index * 100 + seconds` (`BUFFER_STATE_STRIDE` = 100, 0-based slot, seconds ≤ 16). It cycles through the slots every 0.25 s, and every change is also sent at once. A slot that is recording reads 0 s.

**Index conversion**: voices are 0-indexed in SC and 1-indexed in Lua, so always pass `voice_idx - 1`. Mod sources go through `engine_mod_source()` (Lua 0 = none / 1-7 → SC -1 / 0-6).

**The `voices` table is the only source of values.** The engine holds no per-voice defaults. `toggle_voice` calls `engine.voiceOn` and then `sync_voice_to_engine`, which sends `setGrainSource` first, then every synth, grain and crossmod value. Param actions reach the engine only while a voice is active. The `v<i>_source` action is the exception: it also reaches stopped voices.

### Invariants that are easy to break (details in `docs/notes/engine.md`)

- **Pattern steps and MIDI notes never create nodes.** They call `retrigger`. Velocity only scales the accent envelope's `levelScale` (sampled at trigger time), never a running signal. The engine check asserts this.
- **Replace, never stack.** A source switch replaces the grain synth. Earlier fading synths are cut with `cutSynth` (the `kill` fade), never a second `release` (EnvGen ignores it). New grain synths are placed with `startPlacedGrainSynth`, never relative to a releasing synth.
- **`openedGate(gate)`** wraps every ASR gate, so a synth gated off in its first block still starts and frees. Never use `gate.max(...)`: it breaks forced releases.
- **Silent bus**: unrouted mod slots read `silentBus`, never control bus 0 (norns allocates the input follower there).
- **Limiter before the tanh saturator** in `\strataMaster`. The engine check asserts the order.
- **Buffer and input sources have no voice synth.** Their grain synth mirrors to `granBuses[i]` (`mirrorLevel` 1) so crossmod keeps working. The synth-source grain synth must keep `mirrorLevel` 0 (it reads that bus, so mirroring would feed back).
- **Buffer memory**: 8 × 2 mono buffers of 16 s (≈ 49 MB). Never allocate longer ones. Bufnums never change.
- **`slotChanges[i]`** guards late replies (load completion, `stopRecord` frame count): a clear or load sent later always wins.
- **File writes** go to a `<path>.<generation>.part` file and are renamed into place. Never open the final path for writing.
- **`\strataFilter`**: never compare a UGen with `==` (that is object identity); use `BinaryOpUGen('==', ...)`.
- **Param → engine** goes through `send_param_to_engine(id, value)` and an `engine_senders[id]` entry (this adds the LFO offsets). Never call `engine.*` from a control param's action directly. LFOs modulate around the stored value and never `params:set` their destination.
- **Scenes**: a new captured field needs `validate_scene` coverage and a migration default (`SCENE_GLOBAL_PARAMS.default`, `VOICE_SCENE_DEFAULTS` or `SCENE_BLOCK_DEFAULTS`). Discrete keys (`DISCRETE_GRAIN_KEYS`, source, mod sources) switch at the end of a transition, never crossfade. A recall sends one full sync per running voice whose source changed, after its params (`scene_recall_in_progress`).
- **Source tests**: use `voice_uses_synth(i)` / `voice_uses_buffer(i)`. Never use `not voice_uses_synth` (that includes input).
- **Grid and arc handlers live on the vport only** (`grid.connect(port)`, `arc.connect`). Never store or attach to the raw device passed to `grid.add`.
- **Arc rings** sweep their range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512) ticks through `arc_sweep_param`. Never give a ring its own scale: the only exceptions are the LFO page's whole-value rings (depth at 10 ticks per percent, clocked rate at 20 ticks per rate), and every ring is drawn through `param_fraction`. The script uses one arc vport (`UI_PAGES.ARC_PORT`, 1): `arc.add`/`arc.remove` of a device on another port are ignored.

## Development & Testing

**On norns:** copy the project to `~/dust/code/`, then restart norns or run `;restart` in maiden. SuperCollider changes need a script restart. Watch the maiden console for errors.

**Off-device checks** (run from the repo root before committing; CI runs all three, see status.md):
- `lua test/run.lua` and `luajit test/run.lua`: behaviour tests against norns stubs (`test/norns_stubs.lua`). The engine stub rejects any `engine.*` call whose name, argument count or types do not match the engine's `addCommand` signatures. The run also includes the sync check and the CLAUDE.md table check.
- `lua test/sync_check.lua`: every `engine.<name>(...)` call has a matching `addCommand` with the same argument count, and every command is used.
- `test/run_engine_check.sh [path/to/norns]`: compiles the engine against norns `sc/core` (default `~/src/norns`, or `$NORNS_DIR`) and runs `test/engine_check.scd` on a silent local scsynth. It needs SuperCollider (`$SCLANG` overrides the path). Run only one at a time per machine (port 57110).
- Add a test to `test/run.lua` for every behaviour change. Script locals are reached through `find_upvalue()`/`local_value()`.
- The stubs mirror the real norns libraries (`~/src/norns/lua`): check behaviour there before changing them. `param.t` holds numeric type codes (`params.tOPTION`, ...), so never compare it with a string (a test enforces this). The stubbed APIs and test helpers (`context.polls.fire`, `context.midi.plug`, `context.set_time`, `context.encoders.deliver`, ...) are listed under "Test harness details" in `docs/notes/lua.md`.
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file: norns compiles every `.sc` under `~/dust`.

**Common norns pitfalls:**
- `UI.List` has no `set_items()`: recreate the list. `UI.List.new(x, y, index, items)` needs every argument.
- `clock.sleep()` works only inside `clock.run(...)`. Never call it in `init()`.
- Param IDs must be unique, and norns has built-ins such as `reverb`. Use prefixed ids (`strata_fx`, ...).
- A group's size `n` must equal the number of params that follow it. Groups cannot nest (the stub errors).

## Code Style Guidelines

**Named constants, never magic numbers.** They live in the Constants block at the top of `strata.lua`: `NUM_VOICES` (7), `NUM_SCENES` (8), `PATTERN_LENGTH` (16), `SCENE_DATA_VERSION` (2), `NUM_MOD_SLOTS` (3), `NUM_UI_PAGES` (5), `MAX_STEP_LEVEL` (15), `NUM_BUFFERS` (8), `BUFFER_SECONDS` (16), `BUFFER_DATA_VERSION` (1), `NUM_LFOS` (3). The engine mirrors them as `numVoices`, `numBuffers` and `bufferSeconds`. Never hardcode 7, 8 or 16 in voice, scene, pattern or buffer code (bare numbers in grid code are coordinates and LED levels).

**Lua's 200-local limit**: `strata.lua`'s main chunk uses 187 locals. Group a feature's constants in one table (as `LFO_PAGE`, `GRID_LAYOUT`, `BUFFER_PAGE`, `FX_PAGE`, `BUFFER_SETTLE` do) or use global functions; never add many top-level `local`s. To measure the headroom, append `local probe1, ..., probeN` to a copy of the script and run `luac -p` on it. The harness fails with "too many local variables" when the limit is hit.

**Descriptive names**: `selected_voice`, not `sv`; `master_density`, not `md`.

**Bounds-check every index** (voice 1..`NUM_VOICES`, scene, step, slot, grid coordinates) before indexing, so tables never grow by accident. **Clean up** every metro, clock, poll and device handler in `cleanup()`, and cancel an existing clock before starting its replacement.

**Keep docs current in the same change**: README.md (user-facing behaviour), this file (rules, command table) and the matching `docs/notes/` file (implementation details), plus `docs/superpowers/status.md`.

### CRITICAL: keep Lua and the engine in sync

- A new or changed `addCommand` needs: matching `engine.*` calls (same count and types; SC type codes i/f/s), the table row above, and the engine stub picks it up from the SC source.
- A new SynthDef argument the user controls needs: the `voices` table default, the voice's `param_order`, `add_voice_params()`, `get_param_spec()`, a sender in `engine_senders`, and the exact case-sensitive name. Grain params go through `setGrainParam` and `GRAIN_PARAM_IDS`.
- Lua defaults are what the engine plays (`sync_voice_to_engine` sends them). SynthDef defaults for the filter and delay must equal the Lua param defaults, because the script never bangs its params.
- New voice-level controls that a buffer or input grain synth also needs belong in `voiceControls` / `grainControls` and `controlNameSets` (see Audio Sources in `docs/notes/engine.md`).

### IMPORTANT: update the UI with every feature (128×64 screen)

- Pages: `UI_PAGES = {"MAIN", "FX", "LFO", "BUFFER", "SETUP"}`, dispatched through `PAGE_DRAW`/`PAGE_ENC`/`PAGE_KEY`/`PAGE_KEY_RELEASE`, with `ARC_PAGE_DELTA`/`ARC_PAGE_REDRAW` indexed the same way. A new page adds its functions to every table, defined above them. Change a page's draw function (`redraw_main`, ...), never `redraw()`.
- Every page has the header at y=8 (`draw_header()`: title, `dens:`, `[M]` at x=98, scene `S1`-`S8` right-aligned at 127) and the hint row at y=62 (`draw_hints()`). On MAIN the voice list (x 0-60, `UI.ScrollingList`, 4 visible rows) sits left of the divider at x=62 and the selected voice's details at x 65-127. Status indicators use `[BRACKETS]`; levels are 15 bright, 4 dim, 1-2 subtle.
- A new voice type needs a `MAIN_PARAMS` entry (E3, the MAIN display and arc ring 2 follow; `list_name` is its voice-list name, at most 5 characters) and `get_param_spec()` specs.
- `test/run.lua` checks every page for overlapping strings, text off-screen, the hint row and the list's bottom edge, and that no MAIN string crosses the divider (width estimate: `stubs.text_width`). Keep it passing.
- Before finishing, check that new values are visible with units, hints match the keys, all 7 voices fit, and nothing leaves 128×64.

### CRITICAL: keep grid and arc in step with the code

- Grid layouts: `grid_key_256/128h/128v/64()` and `grid_redraw_*()`, chosen by exact `cols`/`rows` in `grid_layout()`. Patterns are `patterns[voice][step]`. Anything the grid shows must call `grid_redraw()` when it changes, wherever it changes (cheap without a grid).
- New params in `param_order` appear on the 256 fader page automatically (`fader_param_ids`, `set_param_from_column`, which follows the controlspec warp). Review whether a feature needs grid buttons or LED feedback on every layout.
- Arc: review whether new params belong on a page's rings (`arc_*_delta`/`arc_*_redraw`, `ARC_FX_RINGS`, `ARC_BUFFER_RINGS`). Ring feedback must use the same ranges as the param specs (`param_fraction`).
- Everything must degrade gracefully when no grid, arc or MIDI device is connected. Update README's grid/arc sections and `docs/notes/lua.md` with new patterns.

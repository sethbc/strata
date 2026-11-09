## Must not break

- AGENTS.md's command table is the engine's interface: one row per `addCommand`, with the same signature and argument count (the docs test reads it). The engine's `numVoices`, `numBuffers`, `standardBufferSeconds`, `numModSlots` and `bufferStateStride` equal the Lua constants (`bufferSeconds` is a tier value: [performance.md](performance.md)).
- Everything runs inside `context.xg`, in this order: `voiceGroup` (the input synth, voice synths, record synths), `processGroup` (grain synths, then mod synths), then filter, delay, reverb and master. Master runs last in `xg`, never after `og`.
- `free` frees every node, bus and buffer the engine made, and nothing that waits for a fade runs afterward.
- Each engine check area (`test/engine_check/<area>.scd`) has a notes file of the same name here and a place in the runner's `areaOrder` (`test/engine_check.scd`), and each notes file here has an area of its name; the docs test checks all three. An on-demand area (`onDemandAreas`: the soak) has no notes file, is in no CI shard and is documented where it is run.
- The engine check builds test sound and checks saved files with C primitives (`h.repeating`, `h.stereoOf`, `h.periodic`, `h.sameFrames`, ...), never a sclang function per sample, and never reads a long file into one array (sclang's garbage collector, `docs/notes/engine/files.md`).

## The engine check and the notes, per area

The engine check is a runner, `test/engine_check.scd`: it boots a silent scsynth on `$STRATA_SC_PORT`, builds the engine and runs the area files `test/engine_check/<area>.scd` in a fixed order (`areaOrder`: structure, voices, grains, lifecycle, memory, buffers, files, effects, performance, then 3.2's rings, freeze, variation and loops, an absent file skipped). `$STRATA_ENGINE_CHECK_AREAS` (comma- or space-separated) runs only the areas it names, still in that order; a name with no area file fails the run (`ENGINE CHECK FAILED: no area <name>`). Each area file returns a function of the helper Event `h`; call a helper as a method (`h.check(condition, message)`, `h.command(\voiceOn, ...)`):

| Helper | What it does |
|--------|--------------|
| `check(condition, message)` | posts `ok` or `FAIL` and counts a failure |
| `command(name, ...)`, `commandTo(engine, name, ...)` | runs an engine command as matron's OSC would (on `h.engine`, or on another engine) |
| `awaitReply(condition, timeout)`, `waitFor(function, timeout)` | wait inside the check routine; a reply that never comes fails |
| `synthNames(group)`, `synthTree(group)` | the synth def names under a node, or one Event (`id`, `def`, `controls`) per synth, from one `/g_queryTree` |
| `voiceSynths(voice)` | the voice's [voice, grain, mod] synths as the engine tracks them |
| `controlFeedsAUGen(def, control)` | whether a UGen of the SynthDef reads the control |
| `getControl(synth, control)`, `bufferSample(buffer, frame)`, `readBus(bus)`, `readBusValue(bus)`, `measure(probe, bus, seconds)` | read values from the server |
| `pollMessages`, `pollValues(name)` | every `/poll/value` message received, or the values of one poll |
| `writeTestFile(path, rate, frames, values)` | a WAV of constant per-channel values; `stereoPath`, `monoPath`, `longPath` and `textPath` are written before the first area |
| `probeFree(n)` | true when n real-time memory probes of 256 KB fit in the pool |
| `startEngine(settings)`, `freeEngine(engine)` | a second engine instance on the same server, in a context of its own (`settings`: Engine_Strata classvars set for its build), and freeing an engine |
| `startAllVoices`, `stopAllVoices(engine)` | every voice started as the check always has (voice 7 on buffer slot 4), and every voice stopped, put back on its synth source and cut until none of its synths is left |
| `engine`, `server`, `context`, `tempDir`, `testDir`, `voiceDefs`, `grainDefs`, `allDefs`, `chainDefs`, `defaultScratchDir` | values |
| `def32` | the names of the check-only copies of 3.2's defs (`record`, `grainRing`, `grainBuf`), built in the runner with `h.engine` (again by `replaceEngine`, since they bake in the engine's `scaleBuffer` bufnum) and compared against on the server |

Each area stops the voices it started. After each area the runner checks `"<area>: leaves no voice, grain or mod synth running"`, clears every slot (so every area starts from empty slots, in a full run as alone) and posts `area <name>: <seconds> s`, which `test/run_engine_check.sh` prints. A full run takes about 3.5 minutes. The areas still depend on running in `areaOrder`: `finishArea` resets the nodes (no voice, grain or mod synth left) and the slots, but not the rest of the engine's state. Grain controls a voice was given (`grainControls`: mode, envelope, buffer position, ...), crossmod settings, mod speeds and the effect settings carry into the areas after it, and structure must run first for its fresh-engine checks. Each area passes alone too, and a new area must not rely on what an earlier one left. At the end the runner frees the engine and checks that none of its nodes is left.

| Area | Check file | Notes | What it covers |
|------|------------|-------|----------------|
| structure | `test/engine_check/structure.scd` | this file | architecture, SynthDefs built, command signatures, a fresh engine, node ordering, buses, `free` |
| voices | `test/engine_check/voices.scd` | `docs/notes/engine/voices.md` | voice SynthDefs, crossmod, the silent bus, `voiceOn` sync, retrigger and velocity, pitchbend, the Resonator, the `\strataMod` guard |
| grains | `test/engine_check/grains.scd` | `docs/notes/engine/grains.md` | the grain SynthDefs and params, audio sources, the mirror, voice-level controls |
| lifecycle | `test/engine_check/lifecycle.scd` | `docs/notes/engine/lifecycle.md` | replace-never-stack, the kill fade, re-gating, `sendToSynth`, the invariant warnings |
| memory | `test/engine_check/memory.scd` | `docs/notes/engine/memory.md` | real-time memory |
| buffers | `test/engine_check/buffers.scd` | `docs/notes/engine/buffers.md` | the slots, their polls, load, record, clear, fade before zeroing, the Lua side |
| files | `test/engine_check/files.scd` | `docs/notes/engine/files.md` | file writes, `.part` files, the scratch directory |
| effects | `test/engine_check/effects.scd` | `docs/notes/engine/effects.md` | filter, delay, reverb, master |
| performance | `test/engine_check/performance.scd` | `docs/notes/engine/performance.md` | the values a performance tier sets |
| rings | `test/engine_check/rings.scd` | `docs/notes/engine/rings.md` | the ring writers, where ring grains read (pitch as rate, the lookback, history), the GrainBuf wrap |
| freeze | `test/engine_check/freeze.scd` | `docs/notes/engine/freeze.md` | freeze per source, the input copy and its fade, the spectral writer |
| variation | `test/engine_check/variation.scd` | `docs/notes/engine/variation.md` | the per-grain draws, the scale and grain quantize |
| loops | `test/engine_check/loops.scd` | `docs/notes/engine/loops.md` | loop regions: where a buffer grain starts, inside the valid region |
| record | `test/engine_check/record.scd` | `docs/notes/engine/record.md` | the record area: head buses, voice taps, recordBuffer's arguments, the recordState poll |
| waveform | `test/engine_check/waveform.scd` | `docs/notes/engine/waveform.md` | the waveform area's peak buffers and neutral hooks |
| positions | `test/engine_check/positions.scd` | `docs/notes/engine/positions.md` | the neutral scan phase |
| soak (on demand) | `test/engine_check/soak.scd` | `docs/notes/engine/files.md` (sclang's garbage collector) | rounds of 60 s loads and saves on a high engine, each saved file checked in every frame |

**On-demand areas** (`onDemandAreas` in the runner: the soak) run only when `$STRATA_ENGINE_CHECK_AREAS` names them (`STRATA_ENGINE_CHECK_AREAS=soak`), never in a full run or a CI shard. They come last in `areaOrder`, have no notes file of their own (the notes of the code they stress say how to run them) and are in no shard; the docs test checks all three. `test/run_engine_check.sh` passes the runner a deadline 30 s under its timeout (`STRATA_ENGINE_CHECK_DEADLINE`, from `$ENGINE_CHECK_TIMEOUT`; 540 s by default), so a long soak given a longer `ENGINE_CHECK_TIMEOUT` gets the time.

**Test sound** is built from C primitives, never a sclang function per sample (sclang's garbage collector under heavy allocation, in `docs/notes/engine/files.md`): `h.repeating(size, values)` (a Signal repeating an Array of values: `putEach` wraps them), `h.stereoOf(left, right)` (two mono channels interleaved), `h.rampSignal(size)` (0, 1, 2, ...; scale it with Signal arithmetic), `h.periodic(period, startFrame, frames)` (a chunk of a signal repeating one period, an Array built once), `h.noise(size, level)` (4801 random values repeated), `h.writeConstantFrames(file, frames, values)` (65536 frames at a time) `h.sameFrames(file, path)` (an open file compared in every sample with another, a chunk at a time into fresh Signals, never read as one big array) and `h.writePeriodicSeconds(file, period, seconds, rate)` (a long periodic stereo file, one second built once at 48 kHz). Polls: `h.pollValues(name)` (one poll's values, from `pollValueLists`) and `h.pollValueNear(name, target, tolerance)` (whether any value came within `tolerance`, by Signal arithmetic); the runner makes every poll List with room for `pollListCapacity` (16384) entries and checks at the end that none outgrew it, since a List growing inside the poll responder corrupted sclang 3.13 (`docs/notes/engine/files.md`).

## Dual-Language System

This project uses two languages that work together:

1. **strata.lua** - The norns script (Lua)
   - User interface and control logic
   - Parameter management
   - Encoder/key handling
   - Communicates with the SuperCollider engine via `engine.*` commands

2. **lib/Engine_Strata.sc** - The audio engine (SuperCollider)
   - All synthesis and audio processing
   - Exposes commands to Lua via `this.addCommand()`
   - Manages audio buses, synths, and signal routing

## Audio Signal Flow

```
Voice Synth → Voice Bus → Ring Writer → Voice Ring → strataGrainRing → Main Bus → Filter → Filter Bus → Delay → Delay Bus → Reverb → Reverb Bus → Master (drift/limiter/saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)

Buffer source:  Buffer pair (L/R) → strataGrainBuf → Main Bus (and mirrored to the Voice Bus → Mod Synth)
Input source:   SoundIn → strataInput → Input Bus → Ring Writer → Input Ring → strataGrainRing → Main Bus (and mirrored to the Voice Bus → Mod Synth)
```

Each of the 7 voices follows this path (synth source; see Audio Sources in `docs/notes/engine/grains.md` for buffer and input sources):
1. Voice synth (strataResonator/strataFM/strataFolder/strataSub/strataPulse/strataKarplus/strataRing) outputs to its own `granBuses[i]`
2. The voice's ring writer (`strataRingWrite`) records `granBuses[i]` into the voice's ring, and the granular processor (`strataGrainRing`) reads that ring and outputs to shared `mainBus` (see `docs/notes/engine/rings.md`). A buffer-sourced voice has no voice synth: `strataGrainBuf` reads its buffer pair; an input-sourced voice's `strataGrainRing` reads the input ring (written from `inputBus`). Both also write their output to `granBuses[i]` (the mirror)
3. Modulation synth (`strataMod`) analyzes voice bus output (the voice synth, or the mirror) and generates control signal to `modBuses[i]`
4. Other voice synths can read from any `modBuses[i]` to modulate their amplitude and/or frequency
5. Each grain synth writes its dry part to `mainBus` and its delay and reverb sends to the mix area's send buses (`voiceOutput`); three master filters (`strataFilter`) process `mainBus` (to `filterBus`) and the two sends; the delay (`strataDelay`) processes the filtered delay send and returns to `delayBus`
6. Reverb (`strataReverb`, or `strataReverbFDN` on high) processes the filtered reverb send plus `delayBus` and returns to `reverbBus` (see `docs/notes/engine/effects.md`)
7. Master (`strataMaster`) sums `filterBus` and the two returns (`masterSum`), applies drift, a `Limiter.ar(sig, 0.95)` safety stage that catches peaks before saturation, then saturation, and outputs to norns output

## Lua ↔ SuperCollider details

The command table itself is in AGENTS.md (the docs test reads it there).

## SynthDef Organization

Each voice type has its own SynthDef with unique parameters:
- `\strataResonator` - DynKlank resonator bank with filtered noise
- `\strataFM` - Two-operator FM with slow modulation
- `\strataFolder` - Wavefolder with sine input
- `\strataSub` - Ultra-low sine with drift
- `\strataPulse` - Pulse width modulation with resonant filtering
- `\strataKarplus` - Karplus-Strong plucked string physical model
- `\strataRing` - Ring modulation between two oscillators

All voice SynthDefs take `t_trig` and `velocity` controls driving an accent envelope (see Retrigger in `docs/notes/engine/voices.md`), gate their ASR through `openedGate` and multiply in `killFade(kill)` like both grain SynthDefs (see `docs/notes/engine/lifecycle.md`), and include multi-source cross-modulation inputs (3 slots):
- `modBus1`, `modBus2`, `modBus3` - Control buses to read modulation signals from (one per slot)
- `modAmpAmt1`, `modAmpAmt2`, `modAmpAmt3` - Amplitude modulation depths (-2 to 2)
- `modFreqAmt1`, `modFreqAmt2`, `modFreqAmt3` - Frequency modulation depths (-2 to 2)
- The 3 modulation signals are mixed together (weighted sum) before application

Shared processing SynthDefs (`\strataGrainRing` is described in `docs/notes/engine/grains.md`, the effects in `docs/notes/engine/effects.md`):
- `\strataMod` - Envelope follower + LFO for generating modulation signals
- `\strataGrainBuf` - Granular processor for a buffer slot (one per buffer-sourced voice); see Audio Sources in `docs/notes/engine/grains.md`
- `\strataInput` - Persistent live input: `SoundIn.ar([0, 1])` to `inputBus`
- `\strataRingWrite` - Persistent ring writer, one per voice and one for the input (see `docs/notes/engine/rings.md`)
- `\strataRecord` - One recording into a slot's buffer pair; reports its frame count on `framesOut`; frees itself when done (or is freed by `stopRecord`)

## Audio Bus Management

Buses are allocated in `alloc` (`numVoices = 7` in the engine must match `NUM_VOICES` in Lua; use it for every per-voice `Array.fill`):
- `numVoices` stereo `granBuses` (one per voice, for audio)
- `numVoices` mono `modBuses` (one per voice, for control signals)
- 1 mono `silentBus` (always 0; "no modulation source")
- 1 stereo `mainBus` (the grain outputs' dry part mixes here; the first filter's input)
- 1 stereo `filterBus` (that filter's output, the master's dry input)
- 1 stereo `delayBus` (the delay's return, read by the reverb and the master)
- 1 stereo `reverbBus` (the reverb's return, master input)
- the mix area's (`areaState[\mix]`, `docs/notes/engine/effects.md`): stereo delay and reverb sends, their filtered copies, and the 2-channel control `fxMix`
- 4 `envBuffers` (grain envelope shapes, 1024 frames each; see `envShape`)
- 1 stereo `inputBus` (live input from `\strataInput`)
- `numBuffers` mono control `recordFrameBuses` (frames recorded so far, for `stopRecord`)
- `numBuffers` (8) slot pairs `buffersL`/`buffersR`, mono, 16 s each (≈ 49 MB total; see `docs/notes/engine/buffers.md`)

Buses, buffers, the input synth and groups are freed in `free` to prevent resource leaks (recordings in progress are canceled first so nothing is written on free).

## Node Ordering

Everything runs inside the engine group `context.xg`, so norns' output group (`og`) and its meters come after the engine:
```
context.xg: voiceGroup (strataInput, voice synths, strataRecord, then the ring writers) -> processGroup (bus-reading grain synths, then mirroring grain synths each before its voice's mod synth) -> strataFilter x3 (dry, delay send, reverb send) -> strataDelay -> strataReverb -> strataMaster
```
`voiceGroup = Group.head(context.xg)`, `processGroup = Group.after(voiceGroup)`, and the three filters, delay, reverb and master are added in that order with `\addToTail` on `context.xg` (a bypass lifted re-creates the delay after the third filter and the reverb before the master). `inputSynth` is added at the head of `voiceGroup` and record synths right after it; the ring writers go to the tail of `voiceGroup` when the engine starts (the rings area). Mod synths go to the tail of `processGroup`. Grain synths are placed by `startPlacedGrainSynth`, so the order holds after any history of source switches and voice restarts: one that reads the voice bus (synth source) at the **head** of `processGroup`, before every grain synth that mirrors into a voice bus (so it never re-grains a releasing mirror); one that mirrors (buffer and input sources) is created at the tail of `processGroup` and then moved before the voice's running `\strataMod` (`moveBefore`), or stays at the tail when the voice has none yet (`gateVoice` starts or re-gates the mod synth after the grain synth; a re-gated mod synth is moved after a mirroring grain synth with `moveAfter`). A move whose target has just freed on the server (its `/n_end` not yet in sclang) only fails, and the mod synth's `onFree` restart goes to the tail; an `/s_new` relative to such a node would create nothing and leave a phantom grain synth that never frees, so no grain synth is ever created relative to another synth. Every grain synth of a voice therefore runs before that voice's mod synth (not necessarily before other voices' mod synths, which do not read its bus); the engine check reads `/g_queryTree` with controls after 0 -> 3 -> 9 -> 0 switches within 1 s.

## Areas

- **Areas.** The engine is built from areas. An area is one method `strataArea<Name>` (its name is `<Name>` with a lowercase first letter) returning an Event: `order`, `allocState` (buses, buffers, state), `addDefs` (adds SynthDefs and returns the names whose controls `controlPairs` must know), `addCommands` (commands and polls), `start` (persistent nodes), `stop` (frees the area's nodes: synths, groups, recordings), `free` (frees its buses and buffers), `effectKeys` (persistent node keys `setSynth` sends to plainly), `grainDefs` (`{ arg source; ... } -> \defName` Associations, the first match wins in `grainDefFor`) and `grainParamHandlers` (`name: { arg voice, value; ... }`, true to skip `setGrainParam`'s store-and-send). Every key but `order` is optional. `alloc` runs `allocState`, then `addDefs`, then (after a sync) `addCommands`, then `start` across all areas in ascending `order`; `free` runs every area's `stop`, then every area's `free`, each pass in descending `order`, so every node is freed before any bus or buffer (the engine check asserts it). A node never goes in `free`, a bus or buffer never in `stop`. `strataAreas` (`StrataUtil.sc`) finds the methods by reflection and refuses two areas with one `order`. Orders: performance 10, voices 20, grains 30, buffers 40, files 50, effects 60, rings 70, scale 80, variation 90, loop 100, freeze 110, mix 120, record 130, waveform 140, positions 150. An area keeps new state in `areaState[\<name>]`.
- Engine files are named `Strata*.sc` (helper classes too: norns compiles every `.sc` under `~/dust`). Extension files add methods only, never variables. Renaming or deleting an engine file needs a norns restart note in the changelog fragment: an old copy left beside a new one would define the same methods twice.
- **Registering an engine area**: a new `lib/engine/Strata<Name>.sc` (`+ Engine_Strata { ... }`) with one `strataArea<Name>` method at a free `order` (above 70 from 3.2: scale 80, variation 90, loop 100, freeze 110, mix 120; 3.3: record 130, waveform 140, positions 150), its state in `areaState[\<name>]`, never a new variable. `lib/Engine_Strata.sc` is never edited. A value a later package changes is a method in the area file that owns it (`bufferStateStride`, `standardBufferSeconds`, `ringSeconds`, `ringGuardSeconds`).

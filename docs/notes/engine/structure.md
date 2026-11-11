## Must not break

- AGENTS.md's command table is the engine's interface: one row per `addCommand`, with the same signature and argument count (the docs test reads it). The engine's `numVoices`, `numBuffers`, `standardBufferSeconds`, `numModSlots` and `bufferStateStride` equal the Lua constants (`bufferSeconds` is a tier value: [performance.md](performance.md)).
- Everything runs inside `context.xg`, in this order: `voiceGroup` (the input synth, the voice synths, then the ring writers), `processGroup` (the synth source's grain synths at its head, then each voice's mix group, holding its buffer and input grain synths and its `\strataVoiceMix` at the tail, just before that voice's mod synth), then the three master filters, the delay, the reverb, the master, and last the record area's tap group (`\strataTapPreMaster`, then every `\strataRecord`), after everything a recording can read. Nothing of the engine runs after `og`. Node Ordering below has the detail.
- `free` frees every node, bus and buffer the engine made, and nothing that waits for a fade runs afterward, even when an area's `stop` or `free` raises; an `alloc` that raises frees what it built and raises again (#499, Areas below).
- Each engine check area (`test/engine_check/<area>.scd`) has a notes file of the same name here and a place in the runner's `areaOrder` (`test/engine_check.scd`), and each notes file here has an area of its name; the docs test checks all three. An on-demand area (`onDemandAreas`: the soak) has no notes file, is in no CI shard and is documented where it is run.
- The engine check builds test sound and checks saved files with C primitives (`h.repeating`, `h.stereoOf`, `h.periodic`, `h.sameFrames`, ...), never a sclang function per sample, and never reads a long file into one array (sclang's garbage collector, `docs/notes/engine/files.md`).

## The engine check and the notes, per area

The engine check is a runner, `test/engine_check.scd`: it boots a silent scsynth on `$STRATA_SC_PORT`, builds the engine and runs the area files `test/engine_check/<area>.scd` in a fixed order (`areaOrder`: structure, voices, grains, lifecycle, memory, buffers, files, effects, mix, performance, rings, freeze, variation, loops, record, waveform, positions, then the on-demand soak), which a docs test compares with the runner's. `$STRATA_ENGINE_CHECK_AREAS` (comma- or space-separated) runs only the areas it names, still in that order; a name with no area file fails the run (`ENGINE CHECK FAILED: no area <name>`). Each area file returns a function of the helper Event `h`; call a helper as a method (`h.check(condition, message)`, `h.command(\voiceOn, ...)`):

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

Each area stops the voices it started. After each area the runner checks `"<area>: leaves no voice, grain or mod synth running"`, clears every slot (so every area starts from empty slots, in a full run as alone) and posts `area <name>: <seconds> s`, which `test/run_engine_check.sh` prints. A full run takes about 12 minutes on 3.14.1 (the area times in the workflow's comment sum to 702 s; the effects area runs about 72 s since the #305 and #306 checks). The areas still depend on running in `areaOrder`: `finishArea` resets the nodes (no voice, grain or mod synth left) and the slots, but not the rest of the engine's state. Grain controls a voice was given (`grainControls`: mode, envelope, buffer position, ...), crossmod settings, mod speeds and the effect settings carry into the areas after it, and structure must run first for its fresh-engine checks. Each area passes alone too, and a new area must not rely on what an earlier one left. At the end the runner frees the engine and checks that none of its nodes is left.

| Area | Check file | Notes | What it covers |
|------|------------|-------|----------------|
| structure | `test/engine_check/structure.scd` | this file | architecture, SynthDefs built, command signatures, a fresh engine, node ordering, buses, `free` (and its containment), `alloc`'s rollback |
| voices | `test/engine_check/voices.scd` | `docs/notes/engine/voices.md` | voice SynthDefs, crossmod, the silent bus, `voiceOn` sync, retrigger and velocity, pitchbend, the Resonator, the `\strataMod` guard |
| grains | `test/engine_check/grains.scd` | `docs/notes/engine/grains.md` | the grain SynthDefs and params, audio sources, the mirror, voice-level controls |
| lifecycle | `test/engine_check/lifecycle.scd` | `docs/notes/engine/lifecycle.md` | replace-never-stack, the kill fade, re-gating, `sendToSynth`, the invariant warnings |
| memory | `test/engine_check/memory.scd` | `docs/notes/engine/memory.md` | real-time memory |
| buffers | `test/engine_check/buffers.scd` | `docs/notes/engine/buffers.md` | the slots, their polls, load, record, clear, fade before zeroing, the Lua side |
| files | `test/engine_check/files.scd` | `docs/notes/engine/files.md` | file writes, `.part` files, the scratch directory |
| effects | `test/engine_check/effects.scd` | `docs/notes/engine/effects.md` | filter, delay, reverb, master |
| mix | `test/engine_check/mix.scd` | `docs/notes/engine/mix.md` | the per-voice mix stage: equality with 3.2 on the server, its placement, values and bad-value reset |
| performance | `test/engine_check/performance.scd` | `docs/notes/engine/performance.md` | the values a performance tier sets |
| rings | `test/engine_check/rings.scd` | `docs/notes/engine/rings.md` | the ring writers, where ring grains read (pitch as rate, the lookback, history), the GrainBuf wrap |
| freeze | `test/engine_check/freeze.scd` | `docs/notes/engine/freeze.md` | freeze per source, the input copy and its fade, the spectral writer |
| variation | `test/engine_check/variation.scd` | `docs/notes/engine/variation.md` | the per-grain draws, the scale and grain quantize |
| loops | `test/engine_check/loops.scd` | `docs/notes/engine/loops.md` | loop regions: where a buffer grain starts, inside the valid region |
| record | `test/engine_check/record.scd` | `docs/notes/engine/record.md` | the record area: sources and the tap group, feedback, loop and fades, arming by level and delay, playable recordings, the head guard, recordState, the end of a take |
| waveform | `test/engine_check/waveform.scd` | `docs/notes/engine/waveform.md` | the waveform area's peak buffers and neutral hooks |
| positions | `test/engine_check/positions.scd` | `docs/notes/engine/positions.md` | the neutral scan phase |
| soak (on demand) | `test/engine_check/soak.scd` | `docs/notes/engine/files.md` (sclang's garbage collector) | rounds of 60 s loads and saves on a high engine, each saved file checked in every frame |

**On-demand areas** (`onDemandAreas` in the runner: the soak) run only when `$STRATA_ENGINE_CHECK_AREAS` names them (`STRATA_ENGINE_CHECK_AREAS=soak`), never in a full run or a CI shard. They come last in `areaOrder`, have no notes file of their own (the notes of the code they stress say how to run them) and are in no shard; the docs test checks all three. `test/run_engine_check.sh` passes the runner a deadline 30 s under its timeout (`STRATA_ENGINE_CHECK_DEADLINE`, from `$ENGINE_CHECK_TIMEOUT`; 1170 s by default, 540 s in CI), so a long soak given a longer `ENGINE_CHECK_TIMEOUT` gets the time.

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

AGENTS.md's diagram:

```
Voice Synth → Voice Bus → Ring Writer → Voice Ring → strataGrainRing → Synth Path ┐
                                                                                   ├→ strataVoiceMix (voice filter, level on the other path, sends) → Main Bus (dry) + Delay Send + Reverb Send → Filter ×3 → Delay → Reverb → Master (drift/limiter/saturation) → Output
Buffer source:  Buffer pair (L/R) → strataGrainBuf → Other Path ──────────────────┤   (the stage mirrors the other path to the Voice Bus → Mod Synth, and writes the voice tap)
Input source:   SoundIn → strataInput → Input Bus → Ring Writer → Input Ring → strataGrainRing → Other Path ┘

Voice Bus → Mod Synth → Mod Bus → Other Voice Synths (cross-modulation, 3 slots per voice)
```

Each of the 7 voices follows this path (synth source; see Audio Sources in `docs/notes/engine/grains.md` for buffer and input sources):
1. Voice synth (strataResonator/strataFM/strataFolder/strataSub/strataPulse/strataKarplus/strataRing) outputs to its own `granBuses[i]`
2. The voice's ring writer (`strataRingWrite`) records `granBuses[i]` into the voice's ring, and the granular processor (`strataGrainRing`) reads that ring and writes the voice's synth path (see `docs/notes/engine/rings.md`; its stage, `strataVoiceMix`, filters and sends it, `docs/notes/engine/mix.md`). A buffer-sourced voice has no voice synth: `strataGrainBuf` reads its buffer pair; an input-sourced voice's `strataGrainRing` reads the input ring (written from `inputBus`). Both write the voice's other path, and only that (a grain SynthDef has one `Out`); the stage writes the other path, filtered and after the level, to `granBuses[i]` (the mirror), so crossmod keeps working, and the voice's whole output to its tap (`docs/notes/engine/record.md`)
3. Modulation synth (`strataMod`) analyzes voice bus output (the voice synth, or the stage's mirror) and generates control signal to `modBuses[i]`
4. Other voice synths can read from any `modBuses[i]` to modulate their amplitude and/or frequency
5. Each voice's stage (`strataVoiceMix`) writes its dry part to `mainBus` and its delay and reverb sends to the mix area's send buses (`voiceOutput`); three master filters (`strataFilter`) process `mainBus` (to `filterBus`) and the two sends; the delay (`strataDelay`) processes the filtered delay send and returns to `delayBus`
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
- `\strataRecord` - One recording into a slot's buffer pair (input, pre-master, post-master or one voice); writes its head and record length to `headOut` and its frame count to `framesOut`; runs in the tap group, frees itself when done (or fades when `stopRecord` gates it). See `docs/notes/engine/record.md`
- `\strataTapPreMaster` - Persistent: writes the master's `masterSum` to `areaState[\record][\preMasterBus]`, the pre-master record source; the tap group's first node

## Audio Bus Management

Buses are allocated in `alloc` (`numVoices = 7` in the engine must match `NUM_VOICES` in Lua; use it for every per-voice `Array.fill`):
- `numVoices` stereo `granBuses` (one per voice, for audio)
- `numVoices` mono `modBuses` (one per voice, for control signals)
- 1 mono `silentBus` (always 0; "no modulation source")
- 1 stereo `mainBus` (the grain outputs' dry part mixes here; the first filter's input)
- 1 stereo `filterBus` (that filter's output, the master's dry input)
- 1 stereo `delayBus` (the delay's return, read by the reverb and the master)
- 1 stereo `reverbBus` (the reverb's return, master input)
- the mix area's (`areaState[\mix]`, `docs/notes/engine/mix.md`): per voice a stereo synth path and other path, stereo delay and reverb sends, their filtered copies, and the 2-channel control `fxMix`
- 4 `envBuffers` (grain envelope shapes, 1024 frames each; see `envShape`)
- 1 stereo `inputBus` (live input from `\strataInput`)
- `numBuffers` mono control `recordFrameBuses` (frames recorded so far, for `stopRecord`)
- `numBuffers` (8) slot pairs `buffersL`/`buffersR`, mono, `bufferSeconds` each (the tier's: 16 s on standard, ≈ 49 MB in all; up to 300 s on high; see `docs/notes/engine/buffers.md` and `docs/notes/engine/performance.md`)
- the rings area's: a stereo ring per voice (`ringSeconds`) and the input ring, with their write-phase buses (`docs/notes/engine/rings.md`); the record area's: per slot a head bus, per voice a stereo tap bus (`voiceTaps`, written by the stage), the tap sink and the pre-master bus (`docs/notes/engine/record.md`); the waveform area's peak buffers, one per slot (`docs/notes/engine/waveform.md`); the scale buffer (`docs/notes/engine/variation.md`); the freeze area's spectral buffers on high (`docs/notes/engine/freeze.md`)

Buses, buffers, the input synth and groups are freed in `free` to prevent resource leaks (recordings in progress are canceled first so nothing is written on free).

## Node Ordering

Everything runs inside the engine group `context.xg`, so norns' output group (`og`) and its meters come after the engine:
```
context.xg: voiceGroup (strataInput, voice synths, then the ring writers) -> processGroup (the synth source's grain synths at the head, then each voice's mix group, its buffer and input grain synths and its strataVoiceMix at the tail, just before that voice's mod synth) -> strataFilter x3 (dry, delay send, reverb send) -> strataDelay -> strataReverb -> strataMaster -> tap group (strataTapPreMaster, then the strataRecord synths)
```
`voiceGroup = Group.head(context.xg)`, `processGroup = Group.after(voiceGroup)`, and the three filters, delay, reverb and master are added in that order with `\addToTail` on `context.xg` (a bypass lifted re-creates the delay after the third filter and the reverb before the master). `inputSynth` is added at the head of `voiceGroup`; the ring writers go to the tail of `voiceGroup` when the engine starts (the rings area); the record area's `start` adds the tap group at the tail of `context.xg` with `\strataTapPreMaster` at its head, and every `\strataRecord` goes to the tail of the tap group, after everything it can read (`docs/notes/engine/record.md`). Mod synths go to the tail of `processGroup`. Grain synths are placed by `startPlacedGrainSynth`, so the order holds after any history of source switches and voice restarts: a synth-source grain synth at the **head** of `processGroup`, any other at the head of its voice's mix group (never next to a synth that may have just freed: a group never ends). The mix area's `start` creates one group per voice at the tail of `processGroup`, with its stage (`strataVoiceMix`) at the group's tail; `startModSynth` adds a mod synth at the tail of `processGroup` and moves that voice's group just before it in the same bundle (and `onFree`'s restart does too), so every grain synth of a voice runs before its stage and the stage before its mod synth (`docs/notes/engine/mix.md`); the engine check reads `/g_queryTree` with controls after 0 -> 3 -> 9 -> 0 switches within 1 s. The mod synths of other voices are not ordered against this one's group, and need not be.

## Areas

- **Areas.** The engine is built from areas. An area is one method `strataArea<Name>` (its name is `<Name>` with a lowercase first letter) returning an Event: `order`, `allocState` (buses, buffers, state), `addDefs` (adds SynthDefs and returns the names whose controls `controlPairs` must know), `addCommands` (commands and polls), `start` (persistent nodes), `stop` (frees the area's nodes: synths, groups, recordings), `free` (frees its buses and buffers), `effectKeys` (persistent node keys `setSynth` sends to plainly), `grainDefs` (`{ arg source; ... } -> \defName` Associations, the first match wins in `grainDefFor`) and `grainParamHandlers` (`name: { arg voice, value; ... }`, true to skip `setGrainParam`'s store-and-send). Every key but `order` is optional. `alloc` runs `allocState`, then `addDefs`, then (after a sync) `addCommands`, then `start` across all areas in ascending `order`; `free` runs every area's `stop`, then every area's `free`, each pass in descending `order`, so every node is freed before any bus or buffer (the engine check asserts it). Neither is undone by one area's error (#499): `free` runs each area's `stop` and `free` under its own `try` (`runAreaPhases`, `StrataUtil.sc`), so an area that raises is named in one `Strata invariant broken` line (`warnInvariant`) and the others still run; `alloc` runs its phases inside one `try`, and when an area raises it stops every area whose `start` began and frees every area whose `allocState` began (`runAreaPhases` again, so an area's `stop` and `free` meet state it may only partly have made), releases what norns' `deinit` would (`releaseCroneRegistrations`: the commands' OSC defs freed, this engine's polls removed from `CronePollRegistry`), leaves `free` nothing to do and raises the error again. norns' `Crone` frees an engine (`deinit`, then `free`) only once its `alloc` has returned, so without the rollback a load that failed late kept the slots, rings and buses until norns restarted, each new try added a set, and the next engine got the dead one's polls (the registry keeps the first poll of a name): its periodic `bufferState` reported the dead engine's slots. `addPoll` (`StrataUtil.sc`, over CroneEngine's) counts only a poll it registers among `pollNames`: a name another engine on the same server holds hands back that poll without making it this engine's, so neither `deinit` nor the rollback removes another engine's poll. The structure area checks all of it: a check-only area whose `stop` and `free` raise, put into a second engine's areas, and an engine whose context raises when the effects area's `start` reads its output bus (made with `newCopyArgs`, so the check calls `alloc` itself and catches the error), each leaving no node, bus or buffer; the rolled-back engine's OSC defs gone and `h.engine`'s polls left in place; and, with `h.engine`'s polls taken out of the registry for the time, no poll of the failed engine left and the next engine reporting its own slots through `bufferState`. A node never goes in `free`, a bus or buffer never in `stop`. `strataAreas` (`StrataUtil.sc`) finds the methods by reflection and refuses two areas with one `order`. Orders: performance 10, voices 20, grains 30, buffers 40, files 50, effects 60, rings 70, scale 80, variation 90, loop 100, freeze 110, mix 120, record 130, waveform 140, positions 150. An area keeps new state in `areaState[\<name>]`.
- Engine files are named `Strata*.sc` (helper classes too: norns compiles every `.sc` under `~/dust`). Extension files add methods only, never variables. Renaming or deleting an engine file needs a norns restart note in the changelog fragment: an old copy left beside a new one would define the same methods twice.
- **Registering an engine area**: a new `lib/engine/Strata<Name>.sc` (`+ Engine_Strata { ... }`) with one `strataArea<Name>` method at a free `order` (above 70 from 3.2: scale 80, variation 90, loop 100, freeze 110, mix 120; 3.3: record 130, waveform 140, positions 150), its state in `areaState[\<name>]`, never a new variable. `lib/Engine_Strata.sc` is never edited. A value a later package changes is a method in the area file that owns it (`bufferStateStride`, `standardBufferSeconds`, `ringSeconds`, `ringGuardSeconds`).

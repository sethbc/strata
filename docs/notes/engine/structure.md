## Must not break

- CLAUDE.md's command table is the engine's interface: one row per `addCommand`, with the same signature and argument count (the docs test reads it). The engine's `numVoices`, `numBuffers`, `bufferSeconds`, `numModSlots` and `bufferStateStride` equal the Lua constants.
- Everything runs inside `context.xg`, in this order: `voiceGroup` (the input synth, voice synths, record synths), `processGroup` (grain synths, then mod synths), then filter, delay, reverb and master. Master runs last in `xg`, never after `og`.
- `free` frees every node, bus and buffer the engine made, and nothing that waits for a fade runs afterward.
- Each engine check area (`test/engine_check/<area>.scd`) has a notes file of the same name here and a place in the runner's `areaOrder` (`test/engine_check.scd`); the docs test checks both.

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

Each area stops the voices it started. After each area the runner checks `"<area>: leaves no voice, grain or mod synth running"`, clears every slot (so every area starts from empty slots, in a full run as alone) and posts `area <name>: <seconds> s`, which `test/run_engine_check.sh` prints. A full run takes about 3.5 minutes.

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
Voice Synth → Voice Bus → Granular Processor → Main Bus → Filter → Filter Bus → Delay → Delay Bus → Reverb → Reverb Bus → Master (drift/limiter/saturation) → Output
                  ↓
              Mod Synth → Mod Bus → Other Voice Synths (cross-modulation)

Buffer source:  Buffer pair (L/R) → strataGrainBuf → Main Bus (and mirrored to the Voice Bus → Mod Synth)
Input source:   SoundIn → strataInput → Input Bus → strataGrain → Main Bus (and mirrored to the Voice Bus → Mod Synth)
```

Each of the 7 voices follows this path (synth source; see Audio Sources in `docs/notes/engine/grains.md` for buffer and input sources):
1. Voice synth (strataResonator/strataFM/strataFolder/strataSub/strataPulse/strataKarplus/strataRing) outputs to its own `granBuses[i]`
2. Granular processor (`strataGrain`) reads from voice bus, outputs to shared `mainBus`. A buffer-sourced voice has no voice synth: `strataGrainBuf` reads its buffer pair; an input-sourced voice's `strataGrain` reads `inputBus`. Both also write their output to `granBuses[i]` (the mirror)
3. Modulation synth (`strataMod`) analyzes voice bus output (the voice synth, or the mirror) and generates control signal to `modBuses[i]`
4. Other voice synths can read from any `modBuses[i]` to modulate their amplitude and/or frequency
5. Filter (`strataFilter`) processes mainBus, outputs to `filterBus`; delay (`strataDelay`) processes filterBus, outputs to `delayBus`
6. Reverb (`strataReverb`) processes delayBus, outputs to `reverbBus`
7. Master (`strataMaster`) applies drift, a `Limiter.ar(sig, 0.95)` safety stage that catches peaks before saturation, then saturation, and outputs to norns output

## Lua ↔ SuperCollider details

The command table itself is in CLAUDE.md (the docs test reads it there).

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

Shared processing SynthDefs (`\strataGrain` is described in `docs/notes/engine/grains.md`, the effects in `docs/notes/engine/effects.md`):
- `\strataMod` - Envelope follower + LFO for generating modulation signals
- `\strataGrainBuf` - Granular processor for a buffer slot (one per buffer-sourced voice); see Audio Sources in `docs/notes/engine/grains.md`
- `\strataInput` - Persistent live input: `SoundIn.ar([0, 1])` to `inputBus`
- `\strataRecord` - One recording into a slot's buffer pair; reports its frame count on `framesOut`; frees itself when done (or is freed by `stopRecord`)

## Audio Bus Management

Buses are allocated in `alloc` (`numVoices = 7` in the engine must match `NUM_VOICES` in Lua; use it for every per-voice `Array.fill`):
- `numVoices` stereo `granBuses` (one per voice, for audio)
- `numVoices` mono `modBuses` (one per voice, for control signals)
- 1 mono `silentBus` (always 0; "no modulation source")
- 1 stereo `mainBus` (granular outputs mix here; filter input)
- 1 stereo `filterBus` (filter output, delay input)
- 1 stereo `delayBus` (delay output, reverb input)
- 1 stereo `reverbBus` (reverb output, master input)
- 4 `envBuffers` (grain envelope shapes, 1024 frames each; see `envShape`)
- 1 stereo `inputBus` (live input from `\strataInput`)
- `numBuffers` mono control `recordFrameBuses` (frames recorded so far, for `stopRecord`)
- `numBuffers` (8) slot pairs `buffersL`/`buffersR`, mono, 16 s each (≈ 49 MB total; see `docs/notes/engine/buffers.md`)

Buses, buffers, the input synth and groups are freed in `free` to prevent resource leaks (recordings in progress are canceled first so nothing is written on free).

## Node Ordering

Everything runs inside the engine group `context.xg`, so norns' output group (`og`) and its meters come after the engine:
```
context.xg: voiceGroup (strataInput, voice synths, strataRecord) -> processGroup (bus-reading grain synths, then mirroring grain synths each before its voice's mod synth) -> strataFilter -> strataDelay -> strataReverb -> strataMaster
```
`voiceGroup = Group.head(context.xg)`, `processGroup = Group.after(voiceGroup)`, and filter, delay, reverb and master are added in that order with `\addToTail` on `context.xg`. `inputSynth` is added at the head of `voiceGroup` and record synths right after it. Mod synths go to the tail of `processGroup`. Grain synths are placed by `startPlacedGrainSynth`, so the order holds after any history of source switches and voice restarts: one that reads the voice bus (synth source) at the **head** of `processGroup`, before every grain synth that mirrors into a voice bus (so it never re-grains a releasing mirror); one that mirrors (buffer and input sources) is created at the tail of `processGroup` and then moved before the voice's running `\strataMod` (`moveBefore`), or stays at the tail when the voice has none yet (`gateVoice` starts or re-gates the mod synth after the grain synth; a re-gated mod synth is moved after a mirroring grain synth with `moveAfter`). A move whose target has just freed on the server (its `/n_end` not yet in sclang) only fails, and the mod synth's `onFree` restart goes to the tail; an `/s_new` relative to such a node would create nothing and leave a phantom grain synth that never frees, so no grain synth is ever created relative to another synth. Every grain synth of a voice therefore runs before that voice's mod synth (not necessarily before other voices' mod synths, which do not read its bus); the engine check reads `/g_queryTree` with controls after 0 -> 3 -> 9 -> 0 switches within 1 s.

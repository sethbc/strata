# 3.7 design facts: the engine

Read-only survey of main 334429aa (2026-11-15) for the 3.7 design: scan, grains, delay, fast modulation, real-time memory. No engine check was run and no server booted: every memory figure below is either quoted from the notes (measured there, with its source) or marked **(est.)**. SuperCollider source quoted from `~/src/supercollider` at tag `Version-3.13.0` (norns' and CI's version) unless said otherwise. "Code wins" marks a place where notes or comments and code disagree.

## 0. The ten facts most likely to change the design

1. **The scan unit is loop lengths per second, and the span it crosses is the loop clipped to each grain's legal starts, per grain.** `slotGrainPos` multiplies the wrapped `bufPos + scan + spread` by `loopLast - loopFirst` (`lib/engine/StrataLoop.sc:54-59`), and `loopLast` is clipped to `highest = validFrames - grainEndMargin - durFrames` (forward). So at loop 0/1 a scan of 1 crosses `validFrames - 4 - durFrames` frames a second, and `durFrames` varies per grain (size jitter, pitch jitter, intervals, reverse). A scan "in seconds" cannot be a fixed fraction rate without deciding what span a second of audio means.
2. **Nothing resets the scan on a step or a note today.** Only a new `\strataGrainBuf` (Phasor starts at 0), `gateVoice`'s re-gate of a releasing slot reader (`StrataLifecycle.sc:172-175, 181`) and Lua's jump (`setGrainParam(v, "t_scanReset", 1)`, `lib/positions.lua:161`) restart it. `retrigger` sends `t_trig` only (`StrataVoices.sc:128-135`); a `noteOn` on a live extra slot sends pitch and accent only (`StrataNotes.sc:374-376`). `t_scanReset` is voice-wide: it reaches every extra note (`setGrainSynths`). One shot's "a step, note or jump restarts it" needs a new path.
3. **Bounce and one shot cannot be done inside `slotScanPhase` alone.** `bufPos` and the spread are added after the scan and the sum is wrapped (`StrataLoop.sc:59`): a folded or clamped scan plus a nonzero `bufPos` still wraps at the loop edge. The fold or clamp has to act on the sum (or the sum be restructured), and the spread wraps across the edge too.
4. **A per-note slice cannot come from the per-note position alone.** `notePos` is a half-range offset: `(bufPos + 0.5 × (m1 + notePos.lag(0.02))).clip(0, 1)` (`StrataModulation.sc:198-200`), `notePos` clipped to -1..1 (`StrataNotes.sc:621`). From `bufPos` 0 it reaches 0.5 at most, it glides over its 20 ms lag, and it is a fraction of the voice's loop. `loopStart`/`loopLength` are voice-wide (not in `perNoteGrainControls`, `StrataNotes.sc:190-195`), so every note of a voice shares one loop.
5. **Every note of a voice reads the voice's one fast-modulation block.** `fastModNoteSlots { ^1 }` (`StrataModulation.sc:24`); every grain synth and note gets `fastModIn` = `fastModBlock(v, 0)` (`StrataModulation.sc:114-118`). A per-note engine envelope on a fast destination needs more note slots (only `fastModNoteSlots` changes, by the addressing rule) and per-note `fastModIn` (engine-owned).
6. **The stage has 0.71 KB of headroom**: `\strataVoiceMix` measures 41.29 KB of its 42 KB check (`docs/notes/engine/memory.md:10`). Two or three UGens more in the stage (an envelope, a trigger tap, a gain) fail the check; the grain defs have room (`\strataGrainBuf` 73.3 of 88 KB, `\strataGrainRing` 63.2).
7. **The delay line is a power of two: 2 s costs 1 MB, and up to 2.729 s costs nothing more; 2.73-5.46 s costs 1 MB more.** `DelayUnit_AllocDelayLine` rounds `ceil(max × SR + 1) + blockSize` up to a power of two (SC 3.13 `server/plugins/DelayUGens.cpp:3440-3455`). +1 MB breaks the high tier's 3.5 MB floor at the tightest case (396-416 KB above it) and the full-pool floor on high (2070-2080 KB against 1280).
8. **A new delay control is lost at a bypass lift unless kept.** `startDelay` re-creates the node from the kept `time`, `feedback`, `mix` only (`StrataEffects.sc:354-359`; kept from `effectDefaults(\strataDelay, [\time, \feedback, \mix])`, `:387`), and `setDelay` is `"fff"`. A ping-pong control needs a new command or a changed signature, its own kept value and a default equal to Lua's.
9. **The engine knows no tempo or beat.** No `TempoClock`, tempo or beat anywhere in `lib/Engine_Strata.sc` or `lib/engine/`. The one clock-sync pattern is Lua computing a phase and the engine setting it: `syncFastLfo` sets `syncPhase` and `t_sync` (block-quantized reset, `StrataModulation.sc:252-253, 433-438`), and `recordBuffer`'s `delay` + `sent` (Lua's wall clock modulo 1000 s) compensates sclang's wait for a record start (`StrataRecord.sc:332-374`). `slotScanPhase`'s Phasor uses no `resetPos` today.
10. **An engine envelope node can be triggered with no new node from the two engine sites that open the step gate**: `retrigger` (`StrataVoices.sc:128-135`, which already sends the stage `t_trig` while the voice runs) and `openStepGate` (`StrataNotes.sc:390-392`, `t_gate` on an extra note's start). A node in `fastModGroup` reads a trigger set on it in the block it lands in, before any grain synth or stage reads the bus; a trigger it read from a bus the stage writes would be one block late (the stage runs after `fastModGroup`). `EnvGen` allocates no real-time memory (only `IEnvGen` does).

## 1. The scan

### The signal path, from controls to a grain's start (`\strataGrainBuf` only)

1. `\strataGrainBuf` declares `bufPos=0, bufRate=1, bufScan=0, ... loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0, ... notePos=0` (`lib/engine/StrataGrainDefs.sc:144-156`).
2. Position offset first: `this.fastModPosition(bufPos, m, notePos)` is passed as the reader's `bufPos` (`StrataGrainDefs.sc:172`):
   `^(bufPos + (this.fastModHalfRanges[1] * (m[1] + notePos.lag(this.noteLag)))).clip(0, 1)` (`StrataModulation.sc:198-200`), half range 0.5 (`:36`), `noteLag` 0.02 s (`StrataNotes.sc:23`). Unit: fractions of the voice's loop. `bufPos` itself is not lagged.
3. `slotGrainReader` (`StrataGrainDefs.sc:326-350`):
   - `slotRate = rate * bufRate * (bufRateScale / serverScale)` (`:330`); `validFrames = Gate.kr(bufFrames, bufFrames > 0)` (`:331`); `frameRate = slotRate * serverScale` (`:336`, signed, slot frames per output frame); `grainDur = dur.min((validFrames - grainEndMargin).max(0) / (readRate * SampleRate.ir))` (`:338`); `grainFrames = grainDur * SampleRate.ir * readRate` (`:339`).
   - `scanPhase = this.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_scanReset)` (`:340`).
   - `spreadDraw = TRand.ar(posSpread * -0.5, posSpread * 0.5, trig)` (`:341`).
   - `start = this.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, frameRate, grainFrames, validFrames, loopStart, loopLength, recHeadBus)` (`:342-343`).
   - GrainBuf's `pos: start * (validFrames / BufFrames.kr(bufnumL))` (`:345`), `level: (bufFrames > 0).lag(0.05)` (`:348`).
4. `slotScanPhase` (`StrataPositions.sc:29-31`):
   `^Phasor.ar(t_scanReset, (this.scanRate(bufScan, freeze) * (1 - scanHold) + scrubRate) * SampleDur.ir, 0, 1)`
   with `scanRate { arg bufScan, freeze; ^bufScan * (1 - freeze) }` (`StrataFreeze.sc:131-133`). No `resetPos` argument (Phasor's fifth input, default 0).
5. `slotGrainPos` (`StrataLoop.sc:46-61`):
   ```
   var reverse = rate < 0;
   var lowest = durFrames * reverse;
   var highest = (validFrames - grainEndMargin - (durFrames * (1 - reverse))).max(lowest);
   var first = loopStart.clip(0, 1);
   var loopFirst = (first * validFrames).max(lowest).min(highest);
   var loopLast = ((first + loopLength.clip(0, 1)).min(1) * validFrames).max(loopFirst).min(highest);
   var frame = loopFirst + ((bufPos.min(this.lastLoopPosition) + scanPhase + spreadDraw).wrap(0, 1) * (loopLast - loopFirst));
   ^this.slotHeadGuard(frame, lowest, highest, rate, durFrames, recHead) / validFrames.max(1)
   ```
   `lastLoopPosition { ^0.999999 }` (`:17`). The wrap is of the sum of position, scan and spread.
6. `slotHeadGuard` (`StrataRecord.sc:262-281`): reads `In.kr(recHead, 2)` (head frame and record length D, -1 and 0 while idle), latched per block; passes `frame` through when the head reads -1, else moves a start in the head's zone to the zone's lower edge (or upper), clipped to `[lowest, highest]`. It has the last word.

The ring grain synth declares the same scan controls but ignores `scrubRate`, `scanHold`, `t_scanReset`, `loopStart`, `loopLength` (`docs/notes/engine/positions.md`, Owns; `docs/notes/engine/loops.md`, last paragraph). A frozen ring's scan is a separate Phasor: `ringScanOffset` (`StrataFreeze.sc:146-150`), `Phasor.ar(K2A.ar(held), bufScan * SampleDur.ir, 0, 1)` reset as `freeze` rises, in ring lengths per second, wrapping, added to the ring reader's lookback (`StrataGrainDefs.sc:298-299`).

### Every event that restarts the Phasor

| Event | Where | Restarts the scan? |
|---|---|---|
| A new `\strataGrainBuf` (voice start with no releasing synth, source switch, a grain synth the watcher starts again, an extra note's start or restart) | `startGrainSynth` (`StrataLifecycle.sc:67-88`), `switchGrainSynth` (`:313-342`), `voiceSynthFreed` (`:213-227`), `startNoteSynth` (`StrataNotes.sc:224-237`), `restartNotes` (`:545-554`) | yes: Phasor starts at its `start`, 0 (SC `Phasor_Ctor`: `ZOUT0(0) = unit->mLevel = ZIN0(2)`, `TriggerUGens.cpp:1521-1537`) |
| `voiceOn` meeting a releasing slot reader | `gateVoice` (`StrataLifecycle.sc:172-175`): `if (synths[grainKey].defName.asSymbol == \strataGrainBuf) { scanRestart = [\t_scanReset, 1] }`, sent with the re-gate (`:181`) | yes |
| `voiceOn` on a running voice | `gateVoice`, no `scanRestart` | no ("lifecycle: a voiceOn on a running buffer voice keeps its scan", `docs/notes/engine/positions.md`) |
| `setGrainParam(v, "t_scanReset", 1)` | handler `StrataPositions.sc:15-20` → `setGrainSynths` (own grain synth and every live extra grain note; `t_scanReset` is not in `perNoteGrainControls`) | yes, every note of the voice; never stored |
| Lua's jump | `lib/positions.lua:161` (`M.jump`, also `set_loop` via jump) | the only Lua sender of `t_scanReset` found (grep of `lib/`) |
| `retrigger` | `StrataVoices.sc:128-135`: `setSynth(voiceKey, velocity, t_trig 1)`, `setGrainSynths(voice, \t_trig, 1)`, stage `velocity, t_trig 1` if running | **no** |
| `noteOn` on slot 0 | `ownNoteOn` (`StrataNotes.sc:498-507`): `noteGate` 1 (and on a frozen synth voice `noteRate`, `velocity`, `t_accent`) | **no** |
| `noteOn` on a live extra slot | `extraNoteOn` `\live` branch (`StrataNotes.sc:374-376`): `notePitchPairs ++ noteAccentPairs` | **no** (its scan runs on) |
| `noteOn` on a releasing or empty extra slot | `cutNote` + `startNote` → new synth (`:377-381`) | yes (its own Phasor at 0) |
| `noteExpression` | `extraNoteExpression`/`ownNoteExpression` (`:405-411`, `:532-536`) | no |

So **each extra buffer note has its own Phasor**, started at 0 when its synth starts, with the voice's `bufScan`, `scrubRate`, `scanHold`, loop and `bufPos` (voice-wide sends), and its own `notePos` and `bufRate`. `docs/notes/engine/notes.md:48`: "Its scan starts at the voice's position, as any grain start does; the playheads show the own note's."

The reset lands at a block start: `t_scanReset` is a control-rate trigger and the rate is control rate, so `Phasor.ar` runs `Phasor_next_kk` (`TriggerUGens.cpp:1540-1559`: `if (previn <= 0.f && in > 0.f) { level = resetPos; }` then the block). Phasor keeps its level in a `double` (`struct Phasor`, `:134-137`) and outputs float.

### A note's position expression

Before the scan and the loop mapping: `notePos` enters `fastModPosition` with `bufPos` (above), so it is a fraction of the voice's loop, in half ranges (`±1` → `±0.5`), lagged 0.02 s, clipped with the sum to 0-1 (a clip, not a wrap), then `.min(lastLoopPosition)`, then the scan and spread are added and wrapped. `noteExpression`'s `position` is clipped to -1..1 (`StrataNotes.sc:621`); the matrix's position offset `m[1]` adds in the same expression.

### What bounce and one shot would need, and the rules they meet

- UGens available: `Fold` (`.fold(lo, hi)`), `Wrap`, `Clip` on an audio-rate signal (`Clip.ar`), `Phasor` (wraps between `start` and `end`, has `resetPos`), `Sweep` (unbounded, double level, resets to 0 on a trigger, `TriggerUGens.cpp:1500-1517`), `Select`. None allocates real-time memory beyond its unit. A clamped integrator (one that stops at an edge and moves back at once when the rate reverses) is not a core UGen: an unbounded `Sweep` clipped keeps accumulating past the edge (a reverse scrub would first unwind the excess); `LocalIn`/`LocalOut` feedback could clamp it but no grain def has a `LocalIn` today (only one per SynthDef is allowed). (Facts about SC; no design proposed.)
- Bounce is a fold of a phase over 0-2 (`Phasor(…, 0, 2).fold(0, 1)`); one shot a phase held at an edge. Either must act on `bufPos + scan` (point 3 of §0), and the spread's wrap at the edge must be decided.
- **`docs/notes/engine/loops.md`, Must not break**: no grain reads past the valid region; the loop's bounds are clipped with audio-rate `max`/`min` at the trigger's sample, "Never `.clip` there"; "No control-rate UGen may read `lowest`, `highest`, the rate or the frames of a grain"; the engine check fails a control-rate `Clip` with an audio-rate input in either grain def (`test/engine_check/loops.scd:212-217`). A one-shot clamp written `x.clip(...)` on a control-rate receiver with audio-rate bounds would trip it.
- **"`loopStart` 0 and `loopLength` 1 give 3.1's starts"** (loops.md), checked "within 1e-5 of the region".
- **"`slotScanPhase` … with the three controls at rest it is 3.2's scan, exactly"** (`docs/notes/engine/positions.md`); the check runs `engine.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_phaseReset)` beside `Phasor.ar(t_phaseReset, rate * SampleDur.ir, 0, 1)` and requires the peak difference `< 1e-6` (`test/engine_check/positions.scd:23-48`). A new argument changes this call; the default mode must keep the difference under 1e-6.
- **Equality at the defaults**: each grain def equals check-only copies of 3.3.2's defs within 1e-6 with every bus at 0 (`docs/notes/engine/modulation.md:4`, `test/engine_check/modulation.scd:166-191`), and the mix area compares with 3.2 (`test/engine_check/mix.scd:72`). A mode at its default must leave the graph's output identical.
- **Fixed-arity callers** of the scan helpers that a signature change touches: `test/engine_check/positions.scd:24`, `loops.scd:39, 68, 84`, `mix.scd:72`, `modulation.scd:190`, the runner's 3.2 copies (`test/engine_check.scd:125, 154, 165, 280`, own copies), `test/engine_check/grains.scd:362` (helper names), and `test/unit/structure_test.lua:1243` (`AREA_CALL_METHODS` lists `slotGrainReader`).
- **The head guard** takes the frame and `[lowest, highest]`; a frame inside that range is all it needs (`StrataRecord.sc:262-281`).
- **Transient scan state** (AGENTS.md; positions.md): `scrubRate`, `scanHold`, `t_scanReset` are never params, scenes or PSETs; every grain start restarts the scan; Lua's playhead resets on the same events.
- A mode control written as `scanMode.round.clip(0, 2)` on its own name is read by the Lua stub as an enumeration (the `grainMode.round.clip(0, 1)` precedent, `StrataGrainDefs.sc:224-227`; `docs/notes/test-harness/engine-stub-and-sync.md`).
- 3.7's roadmap also says "no real-time memory" for scan modes: a few UGens per `\strataGrainBuf` do cost graph memory (§7).

## 2. The grain SynthDefs and their controls

### Control lists

`\strataGrainRing` (`StrataGrainDefs.sc:104-117`): `out, gate=1, bufL=0, bufR=0, phaseBus=0, bufScan=0, grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5, envBuf=-1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1, modBus1-3=0, modFreqAmt1-3=0, history=0, ringLevel=1, freeze=0, freezeMode=0, reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0, interval1-8=0, intervalCount=0, intervalProb=1, quantize=0, scaleNote=60, loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0, noteGate=1, noteBend=1, noteAmp=1, notePos=0, noteSize=0, velocity=1, t_accent=0, noteRate=1`, plus named `\recHeadBus` and `\fastModIn`.

`\strataGrainBuf` (`:145-158`): the same, with `bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0` in place of `bufL, bufR, phaseBus, bufScan`, and no `noteRate` (the Event's `noteRate` is the literal 1, `:169`).

The arg lists are literal so the Lua stub reads them (`:77-79`); `setGrainParam` accepts a name of either def (`docs/notes/test-harness/engine-stub-and-sync.md`, Param names). The structure check requires both defs to declare `recHeadBus, scrubRate, scanHold, t_scanReset` (`test/engine_check/structure.scd:382-384`).

### How a control is added and reaches a synth

- `grainControls[voice]` (a Dictionary per voice, `StrataVoices.sc:40`) keeps every `setGrainParam` value not handled by an area (`StrataVoices.sc:156-165`: handler first, else store and `setGrainSynths`). `voiceOn` merges `grainSize`, `grainDensity`, `pitchShift` into it (`:99-101`).
- `voiceControls[voice]` keeps `setVoiceParam` and crossmod values, reset by `voiceOn` (`:89-94`); for a buffer or input source `setVoiceControl` also sends the controls the grain def has (`StrataVoices.sc:254-266`).
- `controlNameSets[defName]` is built once in `alloc` from each def's control names, for the names the areas' `addDefs` return (`lib/Engine_Strata.sc:139-143`; grains area returns `[\strataGrainRing, \strataGrainBuf]`, `StrataGrainDefs.sc:27`). `controlPairs(defName, dict)` keeps only the pairs whose key the def has (`StrataUtil.sc:51-58`).
- A grain synth starts with `[\out, path] ++ source pairs ++ grainControlPairs(voice) ++ notePairs/ownNotePairs` (`StrataLifecycle.sc:67-80`); `grainControlPairs` = `controlPairs(def, grainControls[voice])`, preceded by `voiceControls` for a non-synth source, followed by `grainReadPairs` (`:40-45`).
- A control the engine sets itself goes in `engineOwnedControls` (`StrataVoices.sc:285-289`), which `setGrainParam`/`setVoiceParam` refuse and the Lua stub reads.
- A per-note control goes in `perNoteGrainControls` (`StrataNotes.sc:190-195`) so voice-wide sends skip it.
- An area handles a param with a literal `grainParamHandlers: (...)` Event (the stub reads its keys).

### Memory: figures and how they are measured

- Limits (`docs/notes/engine/memory.md`, Must not break): each grain synth **under 88 KB** (`\strataGrainRing` 63.2 KB, `\strataGrainBuf` 73.3 KB with 3.5's note controls, the memory area alone on 3.13: 24.8 and 14.7 KB under; `:10`); each mix stage **under 42 KB** (41.29 KB since 3.5's `t_gate`, 0.71 KB under; `:10`); record synth at most 24 KB, head guard at most 8 KB per `\strataGrainBuf` (`:9`); engine LFO under 9 KB, scatter under 45 KB, offset node under 13.5 KB (`:11`); voice defs each by name (`:12`).
- Measurement (`test/engine_check/memory.scd:105-123`): small graph probes (`\strataCheckPoolProbe`, 240 control values, about 16-17 KB each, `:750-753`) flooded with `/error -1` until the pool is full, with and without twenty synths of the def (forty for the stage), so a reading moves in steps of a probe / 20 (about 0.85 KB) or / 40 (about 0.42 KB). Calibrated against four 256 KB `DelayN` probes (`:76-85`). 3.13 has no `/rtMemoryStatus`.
- What costs pool memory (memory.md:19-21): a `GrainBuf`'s grain table (`maxGrains` 128 → 13.6 KB measured per `GrainBuf`, two per synth: about 26 KB), delay lines and tables (`DelayN/L/C`, `Pluck`, `PV_*`, `LocalIn`'s small bus buffer), and about 250 bytes per UGen of graph (unit structs, inputs, outputs). Derived from the measured steps: 3.4's +8 UGens on `\strataGrainBuf` cost +1.7 KB, 3.5's +14 UGens (with controls) +4.2 KB, scatter's +35 `Lag.kr` +7.6 KB: **about 0.21-0.30 KB per UGen** (derived, not a measurement of its own). `EnvGen` allocates nothing of its own (SC 3.13 `LFUGens.cpp`: `RTAlloc` only in `IEnvGen_Ctor`, `:3238`). `LocalIn` allocates `numChannels × blockSize` floats plus a little (`IOUGens.cpp:1542-1556`). Control buses take no pool memory (`docs/notes/engine/modulation.md:40`).
- "No `LocalBuf` in any engine SynthDef" (structure test); "never size a delay line or table from a control"; every `GrainBuf` uses `maxGrains` (memory.md:3).

### Where a per-slot gain could enter (facts only)

- The engine's per-slot state: `bufferFrames`, `bufferSampleRates`, `slotChanges`, `bufferLoads`, `recordSynths`, `recordFrameBuses` (`lib/Engine_Strata.sc:37-44`), the record area's head buses (`areaState[\record][\headBuses]`, one 2-channel control bus per slot: `[head, D]`, `-1, 0` idle, `StrataRecord.sc:51, 56-60`), the waveform area's peaks (`areaState[\waveform][\peaks][index]`, 64 values, `StrataWaveform.sc:21, 26, 48-51`, and a server peak buffer per slot, `slotPeakBuffer`).
- A grain synth learns its slot only through controls: `bufferSlotPairs` = bufnums ++ `slotLengthPairs(slot)` (`StrataLifecycle.sc:93-97`), and `slotLengthPairs` = `[\bufFrames, frames, \bufRateScale, bufferRateScale(index)]` when the slot holds audio, else `[\bufFrames, 0]`, plus `[\recHeadBus, headBus.index]` (`:102-106`). `bufferRateScale = bufferSampleRates[index] / server.sampleRate` (`StrataBuffers.sc:177-179`). These go at the synth's start, at `gateVoice`'s re-gate (`StrataLifecycle.sc:181`), and from `bufferChanged` to every live reader (own grain synth and live grain notes; others get `bufFrames 0` only, `StrataBuffers.sc:191-203`). The only per-slot bus a grain synth reads is the head bus (`In.kr(recHead, 2)` in the guard).
- Inside the def: the reader returns `level: (bufFrames > 0).lag(0.05)` (`StrataGrainDefs.sc:348`), which `grainSignal` multiplies into the fade, outside the note gain's `.clip(0, 2)` (`:249-250`). The stage applies `voiceLevel(amp, modSig, accent)` = `(amp × (1 + modSig) × (1 + accent)).clip(0, 2)` on the other path after the voice filter (`StrataMix.sc:52-54`), and the other path is what the mirror (crossmod) and the voice tap carry.
- Every note of a voice reads the voice's slot (`startNoteSynth` → `startGrainSynth` → `bufferSlotPairs(voice)`), so a slot gain and a voice gain coincide for buffer voices, but not for the mirror and the tap, and not for input voices.

### How `bufRate` and pitch reach the grain rate; where "rate 1 is the root" lives

- `grainSignal`: `fastMod` first (`pitchShift × noteRate + 1.875 m0`, clipped 0.25-4, `StrataModulation.sc:187-192`); `bendRate = (1 + rateLevel × (bend × (1 + rateMod) − 1)) × noteBend.lag(0.02)` (`StrataGrainDefs.sc:222`); `rate = grainRate(trig, pitchShift, bendRate, vary)` = `pitchShift × semitones.midiratio × bendRate × sign` (`StrataVariation.sc:35-50`), quantize before bend (`quantizedOffset`, `StrataScale.sc:135-139`: `base = scaleNote + pitchShift.ratiomidi`, rounded, offset from `scaleBuffer`). Then `slotRate = rate × bufRate × (bufRateScale / BufRateScale.kr)` (`StrataGrainDefs.sc:330`).
- A buffer voice's own pitch is `bufRate` (Lua `v<i>_buf_rate` 0.25-4) times `pitchShift`; an extra buffer note's pitch is its own `bufRate` = its `noteOn` rate (`notePitchPairs`, `StrataNotes.sc:148`), with its own `scaleNote` = `areaState[\scale][\notes][voice] + rate.ratiomidi` (`noteScaleNote`, `StrataScale.sc:54-56`). The own note's `scaleNote` = Lua's reference + `bufRate.ratiomidi` (`scaleNoteFor`, `:43-49`); Lua's reference for a buffer or input voice is "the root + 60" (comment `:38-40`).
- **"Rate 1 is the root note"**: the engine's `noteRateRootNote { ^60 }` (`StrataNotes.sc:25-27`, equal to Lua's `NOTES.rate_root_note`, a docs test) and `absoluteNoteRate(note)` = `2 ** ((note − 60) / 12)` clipped 0.25-4 (`:34-36`), used by `leaveStream` when a ring-stream note restarts on a buffer (`:41-43`, ruling 53). The engine has no notion of a sample's key: rate 1 plays the file at its own pitch (with `bufRateScale` for its sample rate). A per-slot root note would meet `absoluteNoteRate` (hardcoded 60), `scaleNoteFor`/`noteScaleNote` (the quantize reference) and Lua's `note_values`.

## 3. The delay

- `\strataDelay` (`StrataEffects.sc:152-157`):
  ```
  arg in, out, time=0.375, feedback=0.4, mix=0, fadeIn=0;
  var delayed = DelayC.ar((In.ar(in, 2) * this.liftFade(fadeIn)) + LocalIn.ar(2), 2, time.lag(0.1).clip(0.01, 2));
  LocalOut.ar(delayed * feedback.clip(0, 0.95));
  Out.ar(out, delayed * mix.clip(0, 1).lag(this.fxMixLag));
  ```
  Stereo by multichannel expansion: two `DelayC` of max 2 s, each channel fed back to itself (no cross-feed). `time.lag(0.1)`: a time change glides over the lag (a `DelayC` time glide repitches the repeats). The Lua stub reads the limits from these literal clips (time 0.01-2, feedback 0-0.95, mix 0-1; `fx_commands`).
- **Its memory**: SC 3.13 `DelayUnit_AllocDelayLine` (`server/plugins/DelayUGens.cpp:3440-3455`; the same code at 3.14.1's head): `delaybufsize = ceil(maxdelaytime × SAMPLERATE + 1) + BUFLENGTH`, then `NEXTPOWEROFTWO`, `RTAlloc(delaybufsize × 4 bytes)`, once at the unit's construction (`DelayUnit_Reset`, `:3464-3477`). At 48 kHz, 64-sample blocks:

  | max time | frames per channel | stereo pool | vs today |
  |---|---|---|---|
  | 2 s (today) | ceil(96001) + 64 = 96065 → 131072 | 1024 KB | |
  | up to 2.7293 s | ≤ 131072 | 1024 KB | +0 |
  | 2.73-5.4600 s | 262144 | 2048 KB | +1024 KB |
  | 5.47-10.9213 s | 524288 | 4096 KB | +3072 KB |

  (computed from the source; the check measures the 1 MB: "a bypassed delay returns its 1 MB to the pool", `freedKB > 900`, `test/engine_check/effects.scd:775-788`.) The memory area measures no delay def of its own: the delay is part of the idle engine and of every worst case.
- At a 2 s maximum a synced time fits a quarter note at 30 BPM or faster, a half note at 60, a whole 4/4 bar at 120, a dotted half at 90; at 2.7293 s a bar needs 87.9 BPM, a half note 44.
- **Ping-pong**: cross-feeding the two channels in `LocalOut` (and choosing what enters each side) uses the existing `LocalIn.ar(2)`/`DelayC` lines: no new delay line, so no new pool memory beyond a few UGens of graph (about 0.2-0.3 KB each, est.; a mode select or crossfade 2-6 UGens: 0.5-1.5 KB once, est.).
- **`setDelay`** (`"fff"`, `StrataEffects.sc:268-274`): keeps `time, feedback, mix` (`keepEffectControls`), then in one bundle sets the node (mix × `effectLive`) and `broadcastFxMix`. No validation in the command (the def clips). **`setBypass`** (`"ii"`, `:277-280`) → `setEffectBypass` through `areaCall` (`:316-349`): bypass sets mix and broadcast to 0, frees the node after `bypassFadeTime` (`fxMixLag` 0.05 s + one block) on `SystemClock` from the handler's time; a lift inside the wait cancels the free; a later lift re-creates it with `startDelay(synths[\filterReverb], \addAfter, 0, 1)` (`:342`), i.e. from the **kept** `time`, `feedback`, `mix` and `fadeIn` 1 (`:354-359`).
- **The default rule**: "SynthDef defaults for the filter and delay must equal the Lua param defaults, because the script never bangs its params" (AGENTS.md); the kept controls start from the def's defaults (`effectDefaults(\strataDelay, [\time, \feedback, \mix])`, `:377-381, 387`); a Lua test sends every `strata_fx` default and compares with the def defaults, and the effects check reads a fresh engine's nodes before any command (#364) (`docs/notes/engine/effects.md`, Must not break). The effects check compares the chain at the defaults with check-only copies of 3.0's delay within -60 dB (`effects.md`, The engine check), so a ping-pong control must default to the present sound.
- Rules met: "Never size a delay line from a control" (effects.md); "Bypass is explicit"; one delay node at most; `effectKeys` get plain sends.

## 4. Fast modulation and the step gate

### What exists (`lib/engine/StrataModulation.sc`, order 160)

- `fastModBus`: control bus of `numVoices × fastModNoteSlots × numFastDestinations` = 35 channels (`:103-108`); `silentFastModBus` 5 channels, never written (`fastModIn`'s default).
- `fastModChannel(voice, noteSlot, destination)` = `index + ((voice × slots + noteSlot) × 5 + destination)` (`:153-158`), the only addressing; destinations 0 pitch, 1 position, 2 size, 3 cutoff, 4 amp (`:15-18`).
- Writers in `fastModGroup`, made `Group.before(voiceGroup)` at the head of `xg` (`:130-135`): `\strataFastOffsets` at its head (35 lagged values, `Out.kr` over the whole bus, `:271-275`), engine LFOs and scatter at its tail. scsynth: the first writer of a control bus in a block overwrites, the others add (modulation.md:8); the offset node writes every channel every block.
- Readers: `fastModRead` = `In.kr(fastModIn, 5)` in both grain defs and the stage (`:177`); grain defs use pitch, size (`fastMod`, `:187-192`) and, in `\strataGrainBuf`, position (`fastModPosition`, `:198-200`); the stage uses cutoff (`filterFreq × 31.62 ** m3`, clipped 20-20000) and amp (`ampOffset = m4`) in `voiceMixMod` (`:221-241`). Half ranges `[1.875, 0.5, 0.245]` (`:36`).
- Engine LFO defs (`:251-258`), one per shape:
  ```
  arg out, rate = 0.25, depth = 0, offset = 0, t_sync = 0, syncPhase = 0, gate = 1;
  var phase = Phasor.kr(t_sync, rate * ControlDur.ir, 0, 1, syncPhase);
  var u = this.fastLfoShape(shape, phase);
  var env = EnvGen.kr(Env.asr(fade, 1, fade), this.openedGate(gate), doneAction: 2);
  Out.kr(out, ((((2 * u) - 1) * depth.lag(fade)) + offset) * env);
  ```
  One channel each. Lifecycle: `setFastLfo` makes, sets, re-gates, `Synth.replace`s (never released) or frees-and-starts (released) (`:377-417`); `stopFastLfo` releases (20 ms) (`:421-428`); `fastLfoEnded` restarts a node whose release ended as it was re-gated, at `fastLfoPhaseNow` (`:351-363`).
- Scatter (`:264-268`), one node, 35 `LFDNoise3.kr` × lagged gains, 0.5 s ASR.
- `setFastOffset` sets one value of the offset node by control index (`:508-513`).
- **Zeroing**: "A channel is zeroed when its last writer ends" (modulation.md:8): an ended LFO's channel `/c_fill` 0 unless its newer node writes it (`fastLfoEnded`), a moved LFO's old channel in the bundle that moves it (`:410, 414-415`), every channel at scatter's end (`:495-503`); `zeroFastModChannels` (`:170-172`).
- **Node counts**: "One node per engine LFO, at most, at every moment, a releasing one included"; scatter one node; the offset node one, an `effectKeys` node (`\fastOffsets`); every message to an LFO or scatter node through `sendToSynth` (modulation.md:6, 9).
- **No def of the area has a `LocalBuf`, a delay line or a table**: all ten are control rate (modulation.md:17). Measured: LFO 4.2-6.7 KB (15-27 UGens), scatter 42.1 KB (182 UGens), offset node 11.0 KB (38 UGens) (memory.md:11, 21). New defs need adding to the memory check's explicit list (`test/engine_check/memory.scd:214-237`: `modulationLimitsKB`, `defNames`).
- Literal methods the stub reads: `numFastDestinations { ^5 }`, `fastModNoteSlots { ^1 }`, `numFastLfos { ^6 }`, `numFastLfoShapes { ^8 }`, `fastModHalfRanges`, `fastModCutoffFactor` (modulation.md:18).

### The step gate

- In the stage (`voiceMixMod`, `:221-241`): controls `seqGate` (0), `gateSeconds` (0.1), `gateRelease` (0.1), `voiceMute` (0), `t_gate` (`\t_gate.tr(0)`);
  `env = EnvGen.kr(Env([0, 1, 1, 0], [this.gateAttackSeconds, gateSeconds.clip(0.005, 120), gateRelease.clip(0.005, 4)]), controls[\t_trig] + t_gate);`
  `voiceGate = (1 − gate.lag(0.02) × (1 − env)) × (1 − mute.lag(0.02))`, on the stage's whole output but the mirror.
- `gateAttackSeconds` rounds 5 ms up to whole control blocks plus 0.01 block (`:62-65`): `EnvGen.kr` ends a segment on its whole blocks without reaching its level (modulation.md:72). A control-rate envelope's segments are block-quantized (1.33 ms at 48 kHz).
- EnvGen restarts a segment from its current level on a new trigger; segment times are read as each segment starts (modulation.md:70).
- **How events reach it**: `retrigger` → stage `velocity, t_trig 1` only while `voiceRunning` (`StrataVoices.sc:133`); an extra note that sounds → `openStepGate` → stage `t_gate 1` (`StrataNotes.sc:382, 390-392`), never for the engine's own restarts. `voiceOn` sends no trigger. The four controls are kept in `grainControls[voice]` via `setStageParam` (`StrataModulation.sc:82-87`, `StrataMix.sc:57-61`).

### What an engine envelope node would have to obey (from the rules above)

- Write only through `fastModChannel` channels; hold offsets only (Lua owns base values); zero its channel when it ends or moves; the cutoff and amp offsets are the stage's (the amp law: `(1 + m4)` in `voiceLevel`, so −1 silences).
- A bound on its node count at every moment, releasing included (the LFO rule's analogue); `sendToSynth` for a node that can end on its own, or `effectKeys` for a persistent one.
- Sit in `fastModGroup` (at its tail, where the LFOs are) so its output is written before readers in the same block.
- Triggered with no new node: a `setSynth`/`sendToSynth` trigger from `retrigger` and `openStepGate` reaches a node in `fastModGroup` in the block the message lands in; one per voice cannot give each extra note its own envelope while `fastModNoteSlots` is 1 (§0 item 5).
- A looping envelope (`Env`'s `loopNode`) loops only while its gate is held above 0 (SuperCollider `Env`/`EnvGen` semantics), and ADSR's sustain needs a held gate or a hold time as a control (the step gate uses `gateSeconds`).
- Memory: `EnvGen` itself allocates nothing; a node of 10-25 UGens and about ten controls is about 4-7 KB (est., by the LFO defs' 4.2-6.7 KB for 15-27 UGens).
- The stage cannot host it (0.71 KB headroom).

## 5. Commands and area structure

- An area adds commands in its `addCommands` hook (`docs/notes/engine/structure.md:104`; e.g. `addCommands: { this.areaCall(\addFastModCommands) }`, `StrataModulation.sc:73`), with `this.addCommand(\name, "sig", { arg msg; ... })`. `lib/Engine_Strata.sc` is never edited; new state in `areaState[\<name>]`; a new area file at a free `order` (orders in use: performance 10 … notes 170, `structure.md:104`).
- `areaCall { arg selector ... args; var result; result = this.performList(selector, args); ^result }` (`StrataUtil.sc:193`): every hook, and every call from a function (a command, `onFree`, `sched`, `fork`, `makeBundle`) of a method that hands a function on (`DEFERRING_CALLS`: `sched`, `fork`, `onFree`, `OSCFunc`, `getn`, `unixCmd`, `addDependant`, and engine methods marked from their bodies such as `watchVoiceSynth`, `afterSlotFade`), checked by `test/unit/structure_test.lua` (`AREA_CALL_METHODS`, `:1243`, and the function-literal scan, #689) (`structure.md:5, 106`). A new node with an `onFree` watcher (an envelope node) falls under it.
- The 3.4/3.5 validation pattern (`StrataModulation.sc:515-545, 555-617`; `StrataNotes.sc:585-636`): `fastModIndicesValid(command, [[name, value, highest], ...])` (whole number 0..highest), then `fastModValuesFinite(command, [[name, value], ...])` (NaN or ±inf), each failure posting one `strata: <command> ignored: ...` line via `postFastModIgnored` and doing nothing; only then clip continuous arguments (`name = msg[i].clip(lo, hi)`), record in `received`, act. Older commands (`setDelay`, `setScale`, `setGrainParam`) do not follow it.
- What the Lua side reads from the SC source (`docs/notes/test-harness/engine-stub-and-sync.md`): every `addCommand` signature (name, count, types; comments stripped first); `msg[i].clip(...)` in a command's own call as its limits; FX controls' literal clips in the def (`fx_commands`, `setSynth(\key, \control, msg[i])`); `name.round.clip(lo, hi)` as enumerations; literal `name { ^N }` methods; SynthDef arg lists and defaults; `grainParamHandlers` literal keys; `engineOwnedControls`, `modSlotControls`, `voiceLevelGrainControls`. A new command needs an entry in the stub's `engine_argument_checks` (`test/norns_stubs.lua:606-732`; "so a new command fails until its limits are decided"), a row in AGENTS.md's table (the docs test), and a Lua caller or a `PENDING_COMMANDS` entry (`test/sync_check.lua`).

## 6. Tempo in the engine

- Not found: no `tempo`, `bpm`, beat or `TempoClock` in `lib/Engine_Strata.sc` or `lib/engine/*.sc` (grep). Clocks used: `SystemClock` (bypass, freeze, files, buffers), `Main.elapsedTime`, `Date.getDate.rawSeconds`.
- `syncFastLfo(lfo, phase)` (`StrataModulation.sc:433-438`): `anchorFastLfo(place, phase)` (sclang: `[phase, Main.elapsedTime, rate]`, `:331-336`) and `sendToSynth(place[\synth].setMsg(\syncPhase, phase, \t_sync, 1))`; the def's `Phasor.kr(t_sync, rate × ControlDur.ir, 0, 1, syncPhase)` jumps to `syncPhase` at the block the message lands in. Lua computes the phase from its clock (Lua's side). The message is immediate, not timestamped, so it lands one block after scsynth receives it, with the matron → sclang → scsynth latency (modulation.md:92: "The sclang clock against the server's adds an error of rate × a few ms").
- The same pattern for a scan: `Phasor.ar` has a `resetPos` input (`TriggerUGens.cpp:1540-1559`: on a rising trigger `level = resetPos`) that `slotScanPhase` does not use (`StrataPositions.sc:30`). A scan rate in beats is expressible today as a `bufScan` Lua computes (loop lengths per second), but the scan runs on the audio sample clock and nothing re-aligns it except a reset to 0.
- The record area's sync: `recordBuffer(..., delay, sent)` starts a take `delay` s after Lua's send time (`sent` = `util.time() % 1000`), by a timestamped bundle (`StrataRecord.sc:332-374, 395-400`), so sclang's wait does not shift it.
- Not established: drift between the audio clock and Lua's clock (internal, MIDI, Link, crow) over a long scan.

## 7. The memory budget

### As it stands (quoted, `docs/status.md:26`, `docs/notes/engine/memory.md`)

| | standard | high (spectral freeze on every voice, FDN) |
|---|---|---|
| floor, eight worst cases | 3072 KB (twelve 256 KB probes) | 3584 KB (fourteen) |
| tightest case free (memory shard, 3.13) | 4650 (eight recordings), 4670 (synth → buffer → synth): 1578-1598 above | 3980-4000 (synth → buffer → synth): 396-416 above, 284-304 counting the spectral writers' late allocations |
| full-pool floor (16 extra notes) | 1280 KB | 1280 KB |
| full-pool cases (memory shard, 3.13) | all-buffer 2540-2560, synth → buffer → synth 2740 | all-buffer 2440, synth → buffer → synth 2070-2080 |
| same, full run in one sclang, 3.14.1 | 2420, 2600 | 2320, 1960 |
| idle engine | 6580 KB free | |

Per def: `\strataGrainBuf` 73.3 / 88 KB, `\strataGrainRing` 63.2 / 88, stage 41.29 / 42, Karplus 80.9 / 83, `\strataRecord` ≤ 24, head guard ≤ 8, LFO ≤ 9 (6.7), scatter ≤ 45 (42.1), offset node ≤ 13.5 (11.0); the delay 1024 KB, the FDN about 202 KB, `FreeVerb2` about 100 KB, the master `PitchShift` about 16 KB. Worst cases run six engine LFOs (smooth/drunk) and scatter on every voice and destination. Counts of `\strataGrainBuf` at the cases: 7 at synth → buffer → synth, 21 at all-buffer, 53 at the all-buffer pool case, 23 at the synth → buffer → synth pool case (memory.md:144-147).

### What (a)-(f) could add (all estimates unless quoted; per-UGen cost 0.21-0.30 KB, derived above)

| Item | Where | Per node (est.) | At the worst cases (est.) |
|---|---|---|---|
| (a) bounce, one shot | `\strataGrainBuf` (and `ringScanOffset` if frozen rings get modes) | 4-8 UGens + 1 control: 0.9-2.4 KB | high tightest (7): 6-17 KB; all-buffer (21): 19-50 KB; all-buffer pool (53): 48-127 KB against 1160-1280 KB of margin |
| (b) scan in seconds or beats | Lua-computed `bufScan`: none; a `resetPos`-style sync control | 0-2 UGens: 0-0.6 KB | ≤ 32 KB at 53 synths |
| (c) slot gain | one control and one product per `\strataGrainBuf` | 0.3-0.6 KB | ≤ 32 KB at 53 synths |
| (c) slot root note | sclang state and Lua (rates, `scaleNote`) | 0 | 0 |
| (d) ping-pong | `\strataDelay`, one node | 0.5-1.5 KB | 0.5-1.5 KB |
| (d) longer delay | `\strataDelay` | ≤ 2.7293 s: 0; to 5.46 s: +1024 KB (computed) | high tightest: −608 to −628 KB under its floor; high pool case: about 1046-1056 KB, under 1280; standard tightest about 554-574 above |
| (e) envelope nodes | `fastModGroup`, control rate | 4-7 KB each | one per voice (7): 28-49 KB; one per voice per destination (35): 140-245 KB, against 284-304 KB on high counting the late allocations |
| (f) slices | per-note loop or slice controls on `\strataGrainBuf` | 2-6 UGens and controls: 0.4-1.8 KB | ≤ 95 KB at 53 synths |

Rules a design meets (memory.md, Must not break; AGENTS.md): every floor above; "A new delay line, table or node per voice needs the budget re-measured"; a new UGen with a delay line or table in a per-voice def multiplies by up to three grain (or two voice) synths per voice; "If a floor ever fails, find which estimate was wrong before cutting anything."

## Disagreements: code wins

1. **The scan's unit.** `docs/notes/engine/grains.md:25` ("`bufScan` moves the position in **valid-region lengths per second**"), the comments at `StrataGrainDefs.sc:135-137` and `StrataFreeze.sc:129-130`, `docs/status.md:16` ("`bufScan` moves in valid-region lengths per second, so a 300 s slot scans 300 s per second at scan 1") and ROADMAP.md 3.7 say valid-region lengths per second. The code scales the phase by `loopLast − loopFirst` (`StrataLoop.sc:59`): **loop lengths per second, of the loop's legal starts** (`StrataPositions.sc:24-26`, `docs/notes/engine/positions.md` and `loops.md` say loop lengths). The two agree only at loop 0/1, and even there the span is `validFrames − 4 − durFrames`, not the region.
2. **`bufPos`'s unit** likewise: `grains.md:25` calls it a fraction of the valid region; in code it is a fraction of the loop (`StrataLoop.sc:59`; loops.md agrees with the code).

## Not found

- Any engine path that restarts a scan on `retrigger`, a step or a live-slot `noteOn`.
- Any per-note loop, slice or scan control.
- Any tempo, beat or clock-alignment state in the engine.
- Whether Lua sends an extra note's `noteOn` before or after the step's `retrigger` in triggered grain mode (an extra note's new synth gets no `t_trig` from `noteOn`, `StrataNotes.sc:224-237`; a `retrigger` sent before it does not reach it): the Lua side's question.
- A measured cost of `Fold`, `Select`, `EnvGen` or a delay cross-feed in these defs (all figures in §7 for them are estimates).

# Facts for the 3.9 reverb freeze plan: engine side and its checks

A read-only survey of the repository on 2026-11-25, at the design's branch (d4034c42: `main`'s tree at 80b28332), against `docs/design/3.9-reverb-freeze-design.md`. Paths are relative to the repository's root; line numbers are that commit's, so find each site by its text.

## 1. lib/engine/StrataEffects.sc (546 lines) and StrataDelay.sc (198 lines)

### StrataEffects.sc
- 14-25 `strataAreaEffects`: order 60; hooks `allocState: { this.areaCall(\allocEffectBuses) }`, `addDefs: { this.areaCall(\addEffectDefs); [] }`, `addCommands: { this.areaCall(\addEffectCommands) }`, `start: \startEffectsChain`, `stop: \stopEffects`, `free: \freeEffects`, `effectKeys: this.effectChainKeys`.
- 30 `effectChainKeys` `[\filter, \filterDelay, \filterReverb, \delay, \reverb, \master]`. 33 `bypassKeys` `[\delay, \reverb]`. 37-39 `bypassFadeTime` (fxMixLag + one block, about 51 ms).
- 41-61 `allocEffectBuses`: buses; `state[\controls]`, `state[\bypassed]`, `state[\pendingFrees]`; **line 56 `this.allocDelayLine;`** (a direct call inside the method, not in a function); line 60 `state[\shimmerRings] = 4.collect({ Buffer.alloc(context.server, this.shimmerRingFrames, 1) });`.
- 81-84 `shimmerRingsFor { arg key; ... ^if (key == \delay) { rings.copyRange(0, 1) } { rings.copyRange(2, 3) } }`.
- 89-91 `emptyShimmerRings { arg key; this.shimmerRingsFor(key).do({ arg buffer; context.server.listSendMsg(buffer.zeroMsg) }) }`.
- 102-112 `shimmerShift`, 156-166 `shimmerLoop(wet, sent, bufs, amount, ratio)`.
- 239-241 `liftFade { arg fadeIn; ^Line.ar(1 - fadeIn, 1, this.fxMixLag) }`.
- **245 `fdnLineSeconds { ^[1487, 1759, 2063, 2543, 2927, 3499, 4271, 5119] / 48000 }`**; **248 `fdnDiffuserSeconds { ^[[0.0053, 0.0079, 0.0131, 0.0239], [0.0061, 0.0089, 0.0149, 0.0271]] }`**.
- **There is no `fdnDefLimitKB` in the engine.** The FDN's pool limits live only in `test/engine_check/memory.scd:327` (section 3).
- 250-365 `addEffectDefs`: `\strataFilter` (258-263); **266 `this.addDelayDef;`** with the comment "The delay (StrataDelay.sc), called here, not inside a function"; `\strataReverb` (279-289), args `in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0, shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2`; **`\strataReverbFDN` (304-334)**, the same args; `\strataMaster` (338-364).
  - The FDN today: `room = size.clip(0, 1).lag(0.1)`, `damping = damp.clip(0, 1).lag(0.1) * 0.4`; `drift = [0, 0, LFNoise1.kr(0.31) * 0.0006, 0, 0, 0, LFNoise1.kr(0.43) * 0.0005, 0]`; `lengths = this.fdnLineSeconds * (0.6 + (0.4 * room)) + drift`; `feedback = LocalIn.ar(10)`; diffusers on `sig + feedback.copyRange(8, 9)`; lines `DelayL.ar((diffused[index % 2] * 0.25) + feedback[index], this.fdnLineSeconds[index] + 0.002, lengths[index] - ControlDur.ir)` then `OnePole.ar(line, damping)`; `sum = lines.sum * (2 / 8)`; `wet` = even lines summed left, odd lines right, each through `zeroBadValues`; `LocalOut.ar(lines.collect({ (line - sum) * (feedbackBase ** (lengths[index] / reference)) }) ++ this.shimmerLoop(...))`; `Out.ar(out, wet * mix.clip(0, 1).lag(this.fxMixLag))`.
  - A comment at 272-274 says the defs' clips stay literals because the Lua stub reads setReverb's and setShimmer's limits from them.
- 367-414 `addEffectCommands`: `setMasterDrift` 368; **`setReverb` "ffff" 375-379** (`this.keepEffectControls(\reverb, (mix: msg[1], size: msg[2], damp: msg[3], delayToReverb: msg[4])); this.setSynth(\reverb, \mix, msg[1] * this.effectLive(\reverb), \size, msg[2], \damp, msg[3], \delayToReverb, msg[4]);`); `setFilter` 384-391; **393 `this.addDelayCommands;`**; `setShimmer` 400-407 (guarded through `fastModValuesFinite`); `setBypass` 410-413 (`this.areaCall(\setEffectBypass, key, msg[2] == 1)`).
- **417-419 `keepEffectControls { arg key, controls; areaState[\effects][\controls][key].putAll(controls); }`**; 422-424 `effectLive`.
- 440-475 `setEffectBypass`: the free runs in `SystemClock.sched(this.bypassFadeTime, ...)` and its bundle (455-459) is `synth.free; if (key == \delay) { this.emptyDelayLine }; this.emptyShimmerRings(key);`. This is where a reverb branch zeroes the sixteen lines and sets the kept `frozen` to 0. A lift (468-471) calls `this.startReverb(synths[\master], \addBefore, 0, 1)`. The comment at 429-431 quotes "229 KB for the FDN".
- **482-494 `startReverb { arg target, addAction, mix, fadeIn = 0; ... }`**: `var args = [\in, ..., \shiftL, rings[0], \shiftR, rings[1], \mix, ..., \shimmerRatio, controls[\shimmerRatio], \fadeIn, fadeIn];` then `if (tier == \high) { synths[\reverb] = Synth(\strataReverbFDN, args, target, addAction); } { synths[\reverb] = Synth(\strataReverb, args, target, addAction); };`.
- 497-501 `effectDefaults(defName, names)` reads `SynthDescLib.global.at(defName).controls` and raises if a name is missing.
- 503-524 `startEffectsChain`: **509-510 `state[\controls][\reverb] = this.effectDefaults(\strataReverb, [\mix, \size, \damp, \delayToReverb, \shimmer, \shimmerRatio]);`**. The kept reverb defaults are read from the standard def, so a `\frozen` added to this list needs `\strataReverb`'s inert `frozen=0`. The delay's list includes `\frozen` (507). 521 `this.startReverb(context.xg, \addToTail);`.
- 528-534 `stopEffects`; **538-545 `freeEffects`**: `this.freeDelayLine;` then the shimmer rings `.free`, then the buses.

### StrataDelay.sc (the pattern for a StrataReverb.sc)
- Header 1-8: "No area of its own: the effects area owns the node and its place in the chain, and calls these."
- 15 `delayLineFrames { ^262144 }`, a literal; 19 `delayFreezeSeconds { ^0.02 }`; 23 `delayFreezeRate { ^1 / this.delayFreezeSeconds }`.
- 58 `delayLine { ^areaState[\effects][\delayLine] }`.
- 63-65 `allocDelayLine { areaState[\effects][\delayLine] = 2.collect({ Buffer.alloc(context.server, this.delayLineFrames, 1) }); }`.
- 68-71 `freeDelayLine { (areaState[\effects][\delayLine] ? []).do({ arg buffer; buffer.free }); areaState[\effects][\delayLine] = nil; }`.
- 80-83 `emptyDelayLine { this.delayLine.do({ arg buffer; context.server.listSendMsg(buffer.zeroMsg) }); this.keepEffectControls(\delay, (frozen: 0)); }`.
- 85-147 `addDelayDef` (`SynthDef(\strataDelay, {...}).add`). The freeze is at 129-133: `hold = Slew.kr(frozen.clip(0, 1), this.delayFreezeRate, this.delayFreezeRate)`, `isFrozen = frozen.clip(0, 1) > 0`, `input * (1 - hold)`, `held = Gate.kr(time.clip(0.01, 5.4), 1 - isFrozen).lag(0.1)`. The loop gain is `feedback.clip(0, 0.95).max(hold)` (144).
- 149-184 `addDelayCommands`; **171-176 `setDelayFreeze`**: `if (this.fastModIndicesValid(\setDelayFreeze, [[\frozen, msg[1], 1]])) { this.keepEffectControls(\delay, (frozen: if (synths[\delay].notNil) { msg[1] } { 0 })); this.setSynth(\delay, \frozen, msg[1]); };`.
- 190-197 `startDelay`: a literal arg list naming `\bufL, this.delayLine[0], \bufR, this.delayLine[1], \shiftL, rings[0], \shiftR, rings[1]`.

### The rule on how def-adding methods are called (#211)
- Documented in `docs/notes/engine/structure.md:7` (Must not break: "A method whose frame outlives its call is called through `areaCall`, never straight from a function ... the structure area checks that every engine SynthDef function's home frame was called through `areaCall`"), with details at :179 and the area registration at :180.
- Tested at runtime by `test/engine_check/structure.scd:132-167` `checkDefCallers`. For every SynthDesc whose function's home method is an `Engine_Strata` method, it walks callers up to 16 frames and must reach `Engine_Strata:areaCall` through method frames only. A function frame on the way fails. The check line is "structure: each engine SynthDef function's home frame was called through areaCall, so it keeps no freed caller (#211; walked %, ...)" and needs `walked >= 20`.
- So a new `addReverbDefs` (or `addReverbDef`) must be called directly in the body of `addEffectDefs`, as `this.addDelayDef;` is at :266: method to method, from `areaCall(\addEffectDefs)`. Never inside a `do`, `collect` or other function. The same holds for allocating the lines in `allocEffectBuses` (as at :56) and freeing them in `freeEffects` (:539).
- Static tests are in `test/unit/structure_test.lua`: `AREA_HOOKS` and `AREA_CALL_METHODS` (1743-1762), `DEFERRING_CALLS` (1776). The tests are "an area hook, strataAreas and a method that keeps a closure are called through areaCall (#211)" at 1846, "a command calls a method that hands a function on only through areaCall (#211)" at 2023, and "a function the engine keeps or runs calls a method that hands a function on only through areaCall (#689)" at 2397.
- A new `setReverbFreeze` that calls only `keepEffectControls` and `setSynth` (as setDelayFreeze does) hands no function on, so it needs no areaCall.
- A new engine file needs no area. Test "every engine file is named Strata*.sc and defines each strataArea method once" (`structure_test.lua:1568`) needs only `lib/engine/Strata%u[%w]*%.sc` and `+ Engine_Strata`. "no .sc file is tracked outside the engine's files (#332)" is at 1614.

## 2. Engine check runner and area layout

### test/engine_check.scd (1283 lines)
- **24-25 `areaOrder`** = `[\structure, \voices, \grains, \lifecycle, \memory, \buffers, \files, \effects, \delay, \shimmer, \mix, \performance, \rings, \freeze, \variation, \tuning, \loops, \record, \waveform, \positions, \modulation, \envelopes, \notes, \onsets, \types, \outrings, \soak]`; 28 `onDemandAreas = [\soak]`. A new `\reverb` must come before `\soak`, which stays last (docs test at 1207). After `\shimmer` is the natural place.
- 30 `areaPath`. 1203-1214: each area file is `.load`ed and must return a function, which is called `area.value(h)`; `finishArea` follows.
- 954-974 `finishArea` checks that no voice, grain or mod synth is left, no note is in a slot, and the polls are unmoved. It also runs `sweepBookkeeping` (#943 conditions at 805-876, among them the effects' [bypassed, pendingFree, synth] legal triples at :829). It puts every voice back on its type, clears every slot, and prints "area %: % s".
- 48-53 `allDefs` lists `\strataReverb` but not the FDN. 83 `chainDefs = [\strataFilter, \strataDelay, \strataReverb, \strataMaster]`.
- 289-296 `check`; **1093-1201 the `h` Event**:
  - values: `engine, server, context, tempDir, testDir, pollMessages, voiceDefs, allDefs, grainDefs, chainDefs, defaultScratchDir, def32, voiceFilter32, voiceOutput32` and the test-file paths;
  - helpers, called as methods: `check, command, commandTo, formatOf, awaitReply(condition, timeout=5), sweepLines, waitFor, awaitLoad, awaitTake, synthNames, synthTree, voiceSynths, noteSynths, wireUnits, noteNodesAgree, controlFeedsAUGen, pollValues, pollValueNear, writeTestFile, repeating, stereoOf, rampSignal, periodic, noise, writePeriodicSeconds, sameFrames, writeConstantFrames, bufferSample, getControl, readBusValue, readBus, measure, probeFree, startEngine(settings), freeEngine(target), putBackPolls, replaceEngine(settings), stopAllVoices, startAllVoices`.
  - **`guarded` and `withIgnoredLines` are not in `h`**: each area defines its own (delay.scd:149, 155).
- Server options (982-986): only `numInputBusChannels = 2` and `memSize = 8192`. Deadline fallback is `{ 2670 }` at :46 (the runner's default 2700 less 30).

### test/engine_check/delay.scd (432 lines, about 23 s): the closest pattern
- 16-31: local aliases (`check`, `command`, `awaitReply`, `getControl`, `readBus`), `powerDb`/`ampDb`, `numWindows = 8, fields = 7`.
- Check-only defs:
  - 43 `\strataCheckDelayStep` (a control bus stepping first, then second at `at`, then third at `endAt`, by `Sweep.kr`);
  - 49 `\strataCheckDelayInput` (unseeded `PinkNoise` until `noiseTo`, plus a sine from `sineFrom`);
  - 61-74 `\strataCheckDelayWindows`: for 8 `[start, end]` windows it integrates on the server `sig.squared.sum`, the 6-24 kHz band (`HPF.ar(HPF.ar(sig, 6000), 6000)` squared), side and mid energy, peak (`RunningMax`), largest difference from `ref`, and largest sample step. That is 7 values a window on a control bus, and the synth frees itself after `seconds` (`Line.kr(0, 0, seconds, doneAction: 2)`).
- 79-80 `allocLine` (two fresh `delayLineFrames` buffers plus two `shimmerRingFrames` rings); 84-87 **`startCheckDelay`**, the one place it starts a `\strataDelay`, on its own buses and line.
- 102-146 **`runCases(cases, seconds)`**: one `Group.after(context.xg)`, and private `Bus.audio` per case (in, out) plus a result `Bus.control`. Everything is created in one `server.makeBundle`, and the wait ends on every analysis node's `/n_end` (`OSCFunc ... argTemplate: [analysis.nodeID]`, then `awaitReply(condition, seconds * 10 + 10)`). The results are read with `readBus`; then the group, buses and buffers are freed.
- **Noise is not seeded in delay.scd.** Windows are chosen as whole loop periods instead.
- 171-204 `checkHeldLoop` is the freeze check: frozen at 1 s, windows from 2 to 9 s, **run for 9.05 s**, bound 0.5 dB on energy and band. Then `checkLoopBehavior` (7.05 s), `checkClearEdge` (3.05 s), `checkFreezeCommand` (296-326), `checkLiftAfterFreedFreeze` (335-371), `checkIgnoredValues` (375-382, two lines through the modulation area's `postIgnored` hook), `checkClearCommand`, and `checkFreshEngine` (404-413, `h.startEngine(())`).
- 415-422: `guarded.("...", check)` calls. 424-431 put the engine back, and an audio-bus leak check (#807) closes the area.

### test/engine_check/shimmer.scd: the FDN's seeding and its sites
- 78-84 `\strataCheckShimmerInput`: noise on its own generator (`RandID.ir(rgen)`, `RandSeed.kr(1, seed)`). runCases passes `\rgen, 8 + index, \seed, 1000 + index` (258), and a case's `input` may override `\seed` (planNanInLoop uses 77).
- **108-113 `\strataCheckShimmerSeed`**: `Out.kr(out, A2K.kr(RandSeed.ar(Impulse.ar(ControlRate.ir), seed)))` reseeds the default rgen 0, which the FDN's two `LFNoise1` drifts draw from, at every control block. runCases places it immediately before its node (277: `case[\seed] !? { Synth(\strataCheckShimmerSeed, [\out, seedBus, \seed, seed], group, \addToTail) }`, then the node at 278). FDN cases pass `seed: 1234`.
- 250-253: a check that `8 + cases.size <= server.options.numRGens` (default 64).
- **217-221 `startCheckNode`**: `Synth(def, [\in, inBus, \delayIn, silent, \out, outBus, \shiftL, buffers[\rings][0], \shiftR, buffers[\rings][1], \mix, 1] ++ line ++ controls, target, \addToTail)`. `line` holds `\bufL`/`\bufR` only for `delayDefs = [\strataDelay, \strataCheckShimmerDelay18]` (30). The buffers come from 243-244: two rings per case, plus a delay line for delay defs.
- 165-192 `\strataCheckShimmerFdn18` is a check-only copy of the pre-shimmer FDN on pool `DelayL` lines: no buffers, 8-wide `LocalIn`, about 208 KB of pool. It stays valid for "shimmer 0 is bit for bit" only if `BufDelayL` equals `DelayL`, which the spike says it does.
- FDN sites (all through `startCheckNode`):
  - :372 planAsBefore `(def: \strataReverbFDN, ..., seed: 1234, ref: 9)` and its Fdn18 twin;
  - :481-483 planPresent;
  - :535-538 planNanInLoop;
  - :576-577 planHeld;
  - planReverbBounded (called at :752);
  - :704-737 checkFresh builds a **high engine** (`h.startEngine((settingsDir: root, modelPath:, meminfoPath:))` with `performance high`) and reads its FDN's `shiftL`/`shiftR`.
- Four batches (746-752), "each under 5 MB of the pool". The area runs about 40 s.

### Every other `\strataReverb` / `\strataReverbFDN` node in the checks
- `test/engine_check/effects.scd`:
  - 1241-1272 `rt60s(defNames)` (`[\strataReverb, \strataReverbFDN]`): `Synth(defName, [\in, inBus, \delayIn, nothing, \out, outBuses[index], \shiftL, rings[index][0], \shiftR, rings[index][1], \mix, 1, \size, 0.8, \damp, 0.5], group, \addToTail)` at 1254, each with 2 rings of its own (1246);
  - 1274-1283 `poolKB(defName)`: `Synth(defName, [\in, inBus, \delayIn, inBus, \out, outBus, \shiftL, rings[0], \shiftR, rings[1]], engine.processGroup, \addToTail)` at 1278, the pool by `floodFit` probes;
  - 1285-1292: RT60 within 30% of FreeVerb2's, and `fdnKB < 512`;
  - 1294-1318: a high engine's FDN, fresh defaults, a lift (the engine's own node);
  - :101 a check-only `\strataCheckPlainReverb` (FreeVerb2).
- `test/engine_check/memory.scd:334` `Synth(name, [\in, privateBus, \delayIn, privateBus, \out, privateBus, \bufL, line[0], \bufR, line[1], \shiftL, rings[0], \shiftR, rings[1], \mix, 1], group)`, twenty nodes of each def sharing one line and one ring pair.
- High engines whose FDN is the engine's own (it would get the engine's lines): effects.scd:1301, shimmer.scd:719, memory.scd:932 (`replaceEngine`, high, buffer_seconds 60).

## 3. memory.scd: FDN size, limits, floors

- 189-196 `sizeOf { arg start; count = 20; before = floodFit; synths = count.collect(start); sync; 0.1.wait; after = floodFit; free; ^(before - after) * probeKB / count }`.
- 318-326 comment; **327 `var delayDefLimitKB = 30, reverbDefLimitKB = 130, fdnDefLimitKB = 235;`**.
- 328-344 `checkDelaySize`: allocates one line (2 × `delayLineFrames`) and 2 rings, then `sizes = [\strataDelay, \strataReverb, \strataReverbFDN].collect({ sizeOf.({ Synth(name, [...], group) }) })`. Each is asserted `(sizes[index] > 0) and: { sizes[index] <= limit }`, with the line "memory: % takes % KB of the pool (at most % KB, by allocation probes)". Called at :969.
- Floors are probe counts, not named constants: `checkMemoryWorstCase(target, probeCount, floorLabel, engage)` (433), called as `checkMemoryWorstCase.(engine, 12, "3 MB")` (976, 12 × 256 = 3072 KB, standard) and `checkMemoryWorstCase.(high, 14, "3.5 MB")` (931, 3584 KB, high). The pool cases use `count` 5 ("1280 KB") at 747, 782, 819, 891.
  - `probeHeadroom` (535-600) computes `freeKB = count*256 + smallProbes*probeKB + reserveKB` and checks `fits` (every 256 KB probe allocated), with the line "memory: % free at the % %: % (about % KB free, ...)".
  - **No check asserts "more above the floor than before".** The 656 KB is a printed figure, so goal 4 needs a run's printed numbers compared by hand, or a new assertion.
  - The high run (920-943) replaces h.engine with a high engine (buffer_seconds 60) and spectral freeze on every voice.
- Figures quoted:
  - `docs/notes/engine/memory.md:10` (Must not break): the effect defs, FDN at most 235 KB (`fdnDefLimitKB`), twenty nodes, one set of check buffers.
  - memory.md "## 3.8: shimmer": table at 383 (`\strataReverbFDN` | 208.1 | 229.2 (225.0, 227.5) | 229.2 | 235); the worst-case table 387-410 ("high, synth -> buffer -> synth | 4300 | 4290 | 4290 (4320 before) | 3584"); text "tightest ... 4290 KB free, 706 above its floor; ... pool full 2000, 720 above 1280".
  - memory.md "## 3.9: the step gate's floor": the tightest pool case 1950 (3.14.1) / 1970 (3.13), 670 above 1280.
  - memory.md:116: 2d's FDN "about 202 KB: each line's DelayL sized by its own length".
  - memory.md:6 and :33: older high figures.
- `docs/status.md:23`: "3.8.0's tightest case, high synth -> buffer -> synth ... leaves 4240 KB free (656 above the 3.5 MB floor), and 1970 KB with the note pool full (... 690 above ... 1280 KB)" (CI run 44461789361, 3.13), and "`\strataReverbFDN` 228.4 (235; a reverb freeze, #819, may take it to 242)".
- Other FDN size quotes: `docs/notes/engine/shimmer.md:37` (FDN 229.2), `StrataEffects.sc:430` comment "229 KB for the FDN", and `docs/notes/engine/effects.md:16,37`.

## 4. Performance arithmetic

- `lib/engine/StrataPerformance.sc:249-254`:
  ```
  highMemoryBytes { arg seconds, sampleRate;
      ^(numBuffers * 2 * seconds * sampleRate * 4)
          + (numVoices * 2 * 2 * this.ringSeconds * sampleRate * 4)
          + (2 * (this.highHistorySeconds + this.ringGuardSeconds + 1) * sampleRate * 4)
          + this.fixedBufferBytes(sampleRate)
  }
  ```
  `fixedBufferBytes` (273-276) is `((2 * delayLineFrames) + (numVoices * 2 * outRingSeconds * sampleRate) + windowBankFrames + wavetableBankFrames + (4 * shimmerRingFrames)) * 4`, which is 13733888 at 48 kHz and counted on both tiers. Its sizes live in this file (`outRingSeconds` 261, `windowBankFrames` 263, `wavetableBankFrames` 266, `shimmerRingFrames` 268). The high-only spectral buffers (StrataFreeze.sc:82) are not counted anywhere.
- The FDN lines are high-only, so they belong in `highMemoryBytes`, not `fixedBufferBytes`: (2048×2 + 4096×4 + 8192×2) × 2 = 73728 frames = 294912 bytes = 288 KB.
- `test/engine_check/performance.scd`:
  - 94-100: `fixedBufferBytes(48000) == 13733888` and its formula;
  - 103-107: the outRings term;
  - 109-112: the delay term against the allocated line;
  - **114-115 hard-coded:** `engine.highMemoryBytes(60, 48000) == ((8 * 2 * 60 * 48000 * 4) + (7 * 2 * 2 * 4 * 48000 * 4) + (2 * (60 + 4 + 1) * 48000 * 4) + 13733888)`;
  - 118-123: the rings term as `highMemoryBytes(16, 48000) - slots - input - fixedBufferBytes`. A new term must be subtracted there too.
- The step-down cases (78-83: MemAvailable 2100000→300, 1800000→120, 1350000→60, 1150000→16, nil→16) keep at least 62,000 kB of margin (highMemoryBytes at 300/120/60/16 s = 958787/418787/238787/106787 KB, +288 each), so they are unaffected.
- **Lua mirrors none of it.** `lib/performance.lua` only parses the active file, per 3.8 plan ruling 10 (`docs/decisions/3.8.md:177`); `grep 13733888|highMemoryBytes` finds nothing in lib/*.lua or test/unit.
- Docs to move:
  - `docs/notes/engine/performance.md:8-9` (the arithmetic, "fixedBufferBytes has no Lua mirror");
  - :24 ("plus 58787 kB", "13412 kB", the thresholds "2007363 kB, 1467363 kB, 1287363 kB");
  - :43 (the check list);
  - AGENTS.md:188 (Buffer memory) and :212 (the tier rule names `fixedBufferBytes`).

## 5. Lua harness pieces a new command touches

- `test/norns_stubs.lua`:
  - **746 `setDelayFreeze = function(args) return range("frozen", args[1], 0, 1) end,`**, inside `local checks = {...}` (about 700-838; setBypass 743, `clearDelay = none` 747, `setShimmer = none` 750). `setReverbFreeze` needs the same entry.
  - 840-842 wraps each with `continuous`.
  - **3266-3268** in `stubs.install`: `for command_name in pairs(context.signatures) do assert(argument_checks[command_name], "the engine stub has no argument check for engine." .. command_name) end`. A missing entry breaks every test that installs the stubs.
- How the stub maps `\reverb` (459-501):
  - It parses every `SynthDef(\name, { arg ...;` arg list (460-473). Items are split on commas, and each must start with an identifier: **an array literal default such as `lines=#[0, ...]` in the arg list would hit the assert "SynthDef \\name: bad argument"**. Sixteen bufnums need named args, a NamedControl (`\x.kr(...)`, not seen by the stub, as `\windowBank.kr(this.windowBank.first.bufnum)` at StrataGrainDefs.sc:206), or a first bufnum of a consecutive run.
  - 477-481: `fx_synthdefs[key] = name` from every `synths[\key] = Synth(\def` in source order, so `\reverb` is the last one read: `\strataReverb` (startReverb's else branch, StrataEffects.sc:492). Keep the FDN branch first, keep the `synths[\reverb] = Synth(\x, ...)` form, and remember that file order is sorted (`stubs.engine_files`, 117-127).
  - 482-500: for each command body, `this.setSynth(\key, ..., msg[i])` gives `fx_commands[command]` and limits from that def's literal clips.
  - The kept defaults the tests read are `spec.synthdef_defaults[def]` (472).
- `test/sync_check.lua:216-217` holds **`sync_check.PENDING_COMMANDS = {` `}`**, empty today, one quoted name per line (e.g. `  "setReverbFreeze",`). A pending name that a Lua file calls fails, and so does one the engine lacks (229-233, 253). The self-test is `stubs_test.lua:2179` "the sync check accepts a pending command that is not called and fails one that is"; the real list must name engine commands.
- **A trap for package 1:** `test/unit/docs_test.lua:470` "the FX SynthDefs' defaults equal the Lua param defaults (#25)" loops `for name, settings in pairs(fx_commands)` and asserts `#calls > 0` "an fx param sends engine.<name>". Any `this.setSynth(\reverb, ...)` in `setReverbFreeze`'s body makes it an fx_command, so with no `reverb_freeze` param yet (package 2) this test fails. PENDING_COMMANDS does not cover it. Options:
  - an exemption for pending commands in that test;
  - setting the node through a method the command calls (the stub reads only the command's own body);
  - landing both packages together, as 3.8 did (7095ff51 engine, 924e803b Lua).

  The same test asserts `defaults[setting.control] ~= nil`, so `\strataReverb` needs a numeric `frozen=0`, and every signature argument must set a control.
- Other tests a new `frozen` control or command trips:
  - `test/unit/fx_hold_test.lua:349-367` "the reverb is offered no freeze on either tier": asserts `not ...engine_signatures_from_source(...).setReverbFreeze` and `not spec.synthdef_controls.strataReverbFDN.frozen`. Package 1 must end these two asserts.
  - docs_test.lua:648 "fx_commands reads every setSynth in a command body (#51)" pins setReverb's mapping string, which is unaffected unless setReverb's body changes.
  - docs_test.lua:635 "each FX param's controlspec lies within the engine's limit" (`compared == 11`): controlspec params only, so a binary is unaffected.
  - `shimmer_test.lua:72-75` defaults: unaffected.
  - `engine_sync_test.lua:1895,1974` use `'^setReverbFreeze%('` only as a fixture string.
  - `params_setup_test.lua:1761-1765`: the param list diff, package 2's business.

## 6. test/unit/shimmer_test.lua node-site test (194-360)

- `engine_check_sources()` (207-215) globs `lib/engine/*.sc`, `test/engine_check/*.scd` and `test/*.scd`.
- **217-218 `NODE_DEFS = {strataDelay = {"\\shiftL", "\\shiftR", "\\bufL", "\\bufR"}, strataReverb = {"\\shiftL", "\\shiftR"}, strataReverbFDN = {"\\shiftL", "\\shiftR"}}`**: the controls each literal site must name.
- `node_sites` (238-284) finds `Synth(`, `Synth.new(` (def first); `Synth.head/tail/before/after/replace` (def second); `Synth.basicNew` plus the next `newMsg(...)`; and `s_new` lists.
- `node_site_problems` (288-318):
  - A literal `\def` takes `NODE_DEFS[def]`.
  - A **variable def** (`Synth(def,`/`defName`/`name`) needs `{"\\shiftL", "\\shiftR"}` if its args name `\delayIn`, or `\bufL` with `\feedback`.
  - A site passes if its arg text holds every control, or if its second argument is a list variable assigned `name = [` earlier in the file whose `[...]` holds them. `startReverb`'s `Synth(\strataReverbFDN, args, target, addAction)` passes this way. An `args ++ extra` second argument would not match the regex `^%(%s*[^,]+,%s*([%a_][%w_]*)%s*,`, so put the lines in the `args` literal, or literally at the site.
- The self-test (322-343) holds each form. The real test (345-358) has `literal >= 6` and `indirect >= 4`. Today's variable sites are shimmer.scd:219, effects.scd:1254 and 1278, and memory.scd:334.
- Requiring FDN line args takes:
  - the FDN's line control names added to `NODE_DEFS.strataReverbFDN`;
  - a rule for variable-def sites that can be the FDN (e.g. needing the lines whenever `\delayIn` appears). Those sites (rt60s, poolKB, the memory probes, startCheckNode) start both reverbs, and passing unused controls to `\strataReverb` is harmless;
  - an extended self-test.
- If the lines are one NamedControl, the test can look for that name.

## 7. Docs and structure tests tied to the engine

- (a) `docs_test.lua:866` "AGENTS.md command table lists exactly the engine's commands": one row per `addCommand`, with the signature and argument count. No maintained doc may name `engine.<gone>(`. `docs/design` is not among the maintained docs. A row `| \`engine.setReverbFreeze(frozen)\` | \`"i"\` | ... |` lands with the engine commit.
- (b) `docs_test.lua:1164` "every engine notes file opens with Must not break"; :1177 "AGENTS.md names the engine notes files" (each `` `docs/notes/engine/<name>.md` `` in AGENTS.md, today's list at line 17); :1189 "the engine check areas and the engine notes files match one to one" (`test/engine_check/reverb.scd` ⇔ `docs/notes/engine/reverb.md`); :1228 "the runner's area order names every area file" against **`ENGINE_CHECK_AREA_ORDER` at `docs_test.lua:1149-1151`**, which must gain `"reverb"` in the same place as areaOrder; :1207 the on-demand area stays last; :1245 "CI's engine shards run every engine check area exactly once" (every area file in exactly one shard of `.github/workflows/test.yml`'s matrix).
  - `structure_test.lua:3733` "the engine notes give the runner's area order and the full run's time (#491)": `docs/notes/engine/structure.md:14`'s parenthesis "(`areaOrder`: structure, voices, ...)" must match the runner's order. Each of AGENTS.md, docs/checks.md, docs/notes/test-harness/engine-check-runner.md, docs/notes/engine/structure.md and test/run_engine_check.sh must say "about N minutes", with N = round(sum of the workflow's area times / 60). Today that is 1788 s, "about 30 minutes"; at 1830 s or more it becomes 31.
  - structure.md's area table (40-69) has no test, but add a `reverb` row.
- (c) `docs_test.lua:855-864` **`AGENTS_WORD_LIMIT = 8000`**; AGENTS.md has 7927 words (`wc -w`), so 73 words of room. Notes word limit: `docs_test.lua:3818-3828` `NOTES_WORD_LIMIT = 9000`, **docs/notes/lua only**; engine notes have no word limit (memory.md is 15857 words).
- (d) `docs_test.lua:943` "AGENTS.md's guarded commands are the commands whose handlers call a guard helper (#808)". The helpers are `fastModIndicesValid`, `fastModValuesFinite` and `postTuningIgnored`, found in the handler or one method down. A `setReverbFreeze` using `fastModIndicesValid` must be in the AGENTS.md:157 sentence, and the test fails both ways.
- (e) `structure_test.lua:1568` engine file names (`lib/engine/Strata<Name>.sc`, extension blocks only, `ENGINE_AREAS` pins area orders: a file with no area needs no entry). The "every repo path the maintained docs name exists (#52)" test (`docs_test.lua:982`) means a doc naming `lib/engine/StrataReverb.sc` or `docs/notes/engine/reverb.md` needs the file in the same commit. "Renaming or deleting an engine file needs a norns restart note"; adding one does not by that rule, though norns needs a SYSTEM > RESTART for any engine change.
- The timeout test **`docs_test.lua:3449` "the engine check's default timeout is half as much again as a full run's area times (#816)"** needs `ENGINE_TIMEOUT_ROOM (1.5) × sum(area times) <= default`. The default is `test/run_engine_check.sh:71` `${ENGINE_CHECK_TIMEOUT:-2700}`. Today 1.5 × 1788 = 2682, so only **12 s of room**. A reverb area of about 75-100 s pushes 1.5 × sum to about 2800 and fails this test. The default must rise (e.g. 3000), and its value and deadline (default − 30) must appear in docs/checks.md, docs/notes/test-harness/engine-check-runner.md, docs/notes/engine/structure.md, test/run_engine_check.sh and test/engine_check.scd (`{ 2670 }` at :46; :3415 "#208" checks `{ default - 30 }` in engine_check.scd).
- `structure_test.lua:3712` (#731): the workflow's area-time table must sum to its stated "N s in all".
- `docs/status.md:29` says "The engine check's 26 areas take 1788 s ... about 30 minutes".

## 8. CI shards

- `.github/workflows/test.yml:299-306` `matrix: areas:`:
  - `buffers,loops,types`
  - `lifecycle,files,positions,notes`
  - `effects,voices,outrings`
  - `mix,variation,grains,structure,performance`
  - `modulation,freeze,envelopes,tuning`
  - `memory,rings`
  - `record,waveform,onsets,delay,shimmer`
- The comment at 295-297: memory shares its shard with no area that builds a high-tier engine. A reverb area that tests a high engine cannot join `memory,rings`.
- Area times are at 267-275 (3.13, run 44395161831): "... shimmer 40, ... delay 23 ...: 1788 s in all". Shard sums: buffers/loops/types about 363 s (slowest); mix… 272; effects… 291; lifecycle… 256; record…shimmer 221; memory,rings 197; modulation,freeze,envelopes,tuning 188. Each shard runs under `ENGINE_CHECK_TIMEOUT=570` inside `timeout ... 600` (:507), job `timeout-minutes: 37`.
  - The least loaded are `modulation,freeze,envelopes,tuning` (188) and `record,waveform,onsets,delay,shimmer` (221).
  - **If reverb joins the record…shimmer shard, the two `if: matrix.areas == 'record,waveform,onsets,delay,shimmer'` steps at test.yml:529 and :550 must be updated.** No test checks those strings.
- Tests: docs_test.lua:1245 (each area in exactly one shard); :3343 "the 3.13 runner's shard list is the workflow's" (`run_engine_check_313.sh -l` reads the workflow); :3382 "every doc that counts CI's engine shards counts the workflow's (#582)" (seven shards: adding a shard means changing "seven" in docs/checks.md:35 and others).
- The table line must gain `reverb <s>` and a new total. Notes files quote their shard (delay.md:65, shimmer.md:52, tuning.md:38, envelopes.md:58, onsets.md:47, modulation.md:145).

## 9. Check server buffers

- The runner sets only `numInputBusChannels = 2` and `memSize = 8192` (engine_check.scd:982-986). `test/run_engine_check.sh` and `run_engine_check_313.sh` pass no `-b`. ServerOptions 3.13 defaults (SC `Version-3.13.0:SCClassLibrary/Common/Control/Server.sc`): **numBuffers 1024**, maxNodes 1024, numRGens 64, numWireBufs 64, memSize 8192. norns' Crone.sc sets none (memSize commented out), so the device has the same defaults.
- Buffers per standard engine (counted from the allocs):

  | Set | Buffers | Where |
  |---|---|---|
  | slots | 16 | StrataBuffers.sc:35-36 |
  | peak buffers | 8 | StrataWaveform.sc:25 |
  | voice and copy rings, input ring | 30 | StrataRings.sc:108-114 |
  | output rings | 14 | StrataOutRings.sc:47-48 |
  | shimmer rings | 4 | StrataEffects.sc:60 |
  | delay line | 2 | StrataDelay.sc:64 |
  | tuning table | 1 | StrataScale.sc:117 |
  | window bank, `allocConsecutive` | 120 | StrataGrainDefs.sc:82 |
  | wavetable bank, `allocConsecutive` | 8 | StrataTypeWave.sc:65 |

  That is **about 203 per standard engine**. High adds 14 spectral buffers (StrataFreeze.sc:82), 217, and the FDN lines make **233**. The check keeps h.engine (standard, about 203) and areas start second engines alongside it (`h.startEngine`), so with one high engine alive about 436 are held, leaving about 588. At 18 buffers per check FDN node (16 lines + 2 rings) that is about 32 nodes, or about 45 with h.engine alone. Fragmentation could block a consecutive run if the lines use one (unverified).
- Pool: the idle engine leaves about 7580 KB free (memory.md shimmer table). The design's expected about 85 KB per new FDN node and 229 KB per check-only copy of today's def bound the minute batch; shimmer's batches keep "each under 5 MB".
- **Unverified:** whether the new def (16 BufDelay reads, 8 more OnePoles alive at once) stays within `numWireBufs` 64. Today's FDN fits; scsynth refuses a graph needing more interconnect buffers than the world has, and norns uses the same 64. Worth an early check in the engine package.

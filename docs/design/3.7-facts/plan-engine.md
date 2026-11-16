# 3.7 plan facts B: the engine packages (0c, 1a, 1b, 1c, 1d engine half)

Read-only survey of the main checkout (`main`, 334429aa), 2026-11-15. No server booted, no engine check run, no tracked file changed. Line numbers are of `main`. Facts already in `docs/design/3.7-facts/engine.md` (E) and `buffers.md` (B) are cited, not repeated. "Not found" marks what could not be established.

## 0. The facts most likely to surprise a planner

1. **The stub reads the delay time's limit only from a literal clip.** `\strataDelay`'s `time.lag(0.1).clip(0.01, 2)` (`lib/engine/StrataEffects.sc:154`) is the only source of `setDelay` argument 1's limit (`test/norns_stubs.lua:386` `CLIP_LIMITS` needs two literal numbers; `synthdef_control_limits` :399-413). `test/unit/docs_test.lua:723` asserts the limit exists (`engine_limit("setDelay", 1, "time")` fails on nil). Writing `this.delayMaxSeconds` in that clip (0c) drops the limit and fails the Lua suite. Also `engine_number` reads a `name { ^N }` method only as an integer (`(%d+)`, :297-301), so a `delayMaxSeconds { ^2.7 }` cannot be read by the stub as it stands.
2. **`setDelay`'s fourth argument touches 23 three-argument calls in the engine check** (effects 18 lines: :430, 463, 493 (`checkChain30`'s `fx.copyRange(4, 6)`), 519, 553, 588, 638, 689, 690, 719, 742, 771, 833, 848 (`sentBy.`), 853, 1009, 1021, 1052; mix 3; record 2), the structure check `formatOf.(\setDelay) == "fff"` (`test/engine_check/structure.scd:283`), and three Lua tests with three-argument `setDelay` (`docs_test.lua:680, 723-725`). The engine check's `command` helper does not check arity (`test/engine_check.scd:306-311`): a three-argument call reaches the handler with `msg[4]` nil.
3. **Five places pin the area list** besides the area file itself: `ENGINE_AREAS` (orders, `test/unit/structure_test.lua:1092-1094`), `areaOrder` (`test/engine_check.scd:24-25`), `ENGINE_CHECK_AREA_ORDER` (`docs_test.lua:1007-1009`), structure.md's `(areaOrder: ...)` sentence (`docs/notes/engine/structure.md:14`, checked by `structure_test.lua:3056-3065`), CI's shard matrix (`.github/workflows/test.yml`, checked by `docs_test.lua:1103-1132`), and AGENTS.md's list of engine notes files (`AGENTS.md:17`, checked by `docs_test.lua:1037-1039`). The soak must stay last in both order lists.
4. **`voiceOn` has no "stopped voice" branch.** The start of a stopped voice is only `voiceRunning(voice)` false before the bundle (`StrataUtil.sc:32-34`; `releaseVoice` moves the trio out of `synths`, `StrataLifecycle.sc:429-435`). 0c must read it before `gateVoice` runs.
5. **`AREA_HOOKS` is the list a new hook must join** for `direct_calls` to require `areaCall` inside it (`structure_test.lua:1236, 1301-1319`); left out, the hook is still scanned by #689's function-literal scan (an Event function), which fails only a direct call of a method that hands a function on.
6. **The modulation check's 3.3 copy and the mix check's 3.2 split copy call the engine's own `slotGrainReader`** with its 15 arguments (`modulation.scd:190-191`, `mix.scd:71-74`; also `loops.scd:84-85`), so a new reader argument changes those calls, and the equality checks then hold the hooks neutral, not the reader. Only the runner's `addDefs32` copies (`test/engine_check.scd:125-171`) and `structure.scd:399-431` hold a verbatim older reader.
7. **New engine LFO-like defs must not start with `strataFastLfo`**: the memory check counts `[LFO, scatter, offset]` nodes in `fastModGroup` by name prefix at every probe and requires `[6, 1, 1]` (`memory.scd:366-370, 779-781`).
8. **The engine check's `areaOrder` is not the alloc order and new areas need no runner code**: `areaPath` finds `test/engine_check/<name>.scd` (`test/engine_check.scd:30, 41-43`); a name with no file fails the run only when requested.

---

## 1. Areas and hooks (0c)

### How `alloc` collects and runs hooks (`lib/Engine_Strata.sc:120-156`)

```
alloc {
    var defNames = List.new, allocated = List.new, started = List.new;
    areas = this.strataAreas;
    areaState = IdentityDictionary.new;
    areas.do({ arg area; areaState[area[\name]] = IdentityDictionary.new });
    effectKeys = areas.inject([], { arg keys, area; keys ++ (area[\effectKeys] ? []) });
    grainDefTable = areas.inject([], { arg table, area; table ++ (area[\grainDefs] ? []) });
    grainParamHandlers = IdentityDictionary.new;
    areas.do({ arg area;
        (area[\grainParamHandlers] ? ()).keysValuesDo({ arg name, handler;
            if (grainParamHandlers[name].notNil) { Error("Strata: two areas handle grain param " ++ name).throw };
            grainParamHandlers[name] = handler;
        });
    });

    try {
        areas.do({ arg area; allocated.add(area); area[\allocState].value });
        areas.do({ arg area; defNames.addAll(area[\addDefs].value ? []) });
        controlNameSets = IdentityDictionary.new;
        defNames.do({ arg defName;
            controlNameSets[defName] = SynthDescLib.global.at(defName).controlNames.collect(_.asSymbol).as(IdentitySet);
        });
        context.server.sync;
        areas.do({ arg area; area[\addCommands].value });
        areas.do({ arg area; started.add(area); area[\start].value });
    } { arg error;
        this.runAreaPhases(started, \stop);
        this.runAreaPhases(allocated, \free);
        this.releaseCroneRegistrations;
        areas = nil;  // nothing left for free
        error.throw;
    };
}
```

- `areas` is a private class variable (`var areas;`, :99): extension methods read it directly; it is `nil` after a rolled-back alloc (:153). `free` runs `runAreaPhases(areas, \stop)` then `\free` (:164-168), each descending (`StrataUtil.sc:223-229`, `reverseDo`).
- `strataAreas` (`StrataUtil.sc:164-180`): reflection over `this.class.methods` for `strataArea<Upper>...`, each called `this.areaCall(method.name)`, name = lowercased first letter; duplicate `order` throws; sorted ascending.
- Duplicate `grainParamHandlers` keys across areas throw at alloc (:130): a new handler key (`rootNote`) must not exist in another area.
- `areaCall` (`StrataUtil.sc:193`): `areaCall { arg selector ... args; var result; result = this.performList(selector, args); ^result }`.

### Where the hook names are enumerated

- `test/unit/structure_test.lua:1236`: `local AREA_HOOKS = { "allocState", "addDefs", "addCommands", "start", "stop", "free" }`. Used by `direct_calls` (:1291-1327: every `this.<name>` inside a hook's `{...}` must be `this.areaCall(\name ...)`) and by the count in the test at :1347-1352 (`hooks >= 50`, pattern `hook:%s*{%s*[^}]*this%.areaCall%(`).
- `AREA_CALL_METHODS` (:1243-1245): `"ringGrainReader", "slotGrainReader", "recordSynthFreed", "inputHeadFrame", "gateVoice", "voiceSynthFreed", "prepareTake", "startFastLfo", "watchFastLfo", "loadSlot", "clearSlot", "saveSlot", "recordSlot", "stopRecordSlot", "setEffectBypass"`; each must be defined and called through `areaCall` at least once (:1357-1360), and never called directly anywhere in `lib/engine/` (:1321-1325).
- `DEFERRING_CALLS` (:1259-1260): `"sched", "fork", "onFree", "OSCFunc", "OSCdef", "Routine", "defer", "getn", "unixCmd", "addDependant"`.
- `frame_guard.kept_functions` (:1459-1479) scans command functions, `grainParamHandlers:` entries and `grainDefs:` lists only; the #689 test (from :1564) scans every function literal of engine methods, Event functions included.
- `docs/notes/engine/structure.md:7` (the hooks in parentheses: `allocState`, `addDefs`, `addCommands`, `start`, `stop`, `free`) and :163 (Areas: the Event keys `order`, `allocState`, `addDefs`, `addCommands`, `start`, `stop`, `free`, `effectKeys`, `grainDefs`, `grainParamHandlers`; "Every key but `order` is optional"; "Orders: performance 10, ... notes 170"). `AGENTS.md:46` lists the same nine keys.
- Not found: any engine check (structure.scd included) that enumerates or rejects unknown area keys. `structure.scd:103-106` inserts a check-only area `(name: \checkRaises, order: 75, ...)`; `structure.scd:378-380` pins only `record 130, waveform 140, positions 150`.
- Structure tests a `voiceHit` hook meets: the #211 `direct_calls` test (:1329) only if `voiceHit` joins `AREA_HOOKS`; the #689 function-literal scan in any case; `ENGINE_AREAS` (:1092) for any new area's order.

### One whole small area (`lib/engine/StrataPositions.sc:12-22`)

```
strataAreaPositions {
    ^(
        order: 150,
        grainParamHandlers: (
            t_scanReset: { arg voice, value;
                this.setGrainSynths(voice, \t_scanReset, value);
                true
            }
        )
    )
}
```

(The loop area is smaller still: `strataAreaLoop { ^(order: 100) }`, `StrataLoop.sc:11-13`.) A full-hook area for the pattern: `strataAreaModulation` (`StrataModulation.sc:68-89`).

### Orders in use (`test/unit/structure_test.lua:1092-1094`, each file's `order:`)

performance 10 (`StrataPerformance.sc:57`), voices 20 (`StrataVoices.sc:11`), grains 30 (`StrataGrainDefs.sc:25`), buffers 40, files 50, effects 60, rings 70, scale 80, variation 90, loop 100, freeze 110, mix 120, record 130, waveform 140, positions 150, modulation 160, notes 170. The design's onsets 180 and envelopes 190 are free. `ENGINE_AREAS` must gain both (the test fails an area missing from it, :1116, and an entry with no area, :1122).

### `areaOrder` and how an area file is found (`test/engine_check.scd`)

```
var areaOrder = [\structure, \voices, \grains, \lifecycle, \memory, \buffers, \files, \effects, \mix, \performance,
    \rings, \freeze, \variation, \loops, \record, \waveform, \positions, \modulation, \notes, \soak];
var onDemandAreas = [\soak];
var areaPath = { arg name; testDir +/+ "engine_check" +/+ (name.asString ++ ".scd") };
```
(:24-25, :28, :30). Areas run are `areaOrder.select({ File.exists(areaPath.(name)) and: { requested or not on-demand } })` (:41-43); a requested name not in `areaOrder` or without a file stops the run (:34-39). Each area file returns `{ arg h; ... }` (header comment :10). `docs_test.lua:1086-1099` requires `areaOrder` to equal `ENGINE_CHECK_AREA_ORDER` (:1007-1009) and to name every file; :1065-1084 requires on-demand areas last; :1047-1061 requires `docs/notes/engine/<area>.md` for every non-on-demand area file and the reverse.

### CI's shards (`.github/workflows/test.yml`, `engine-shard.strategy.matrix.areas`)

```
        areas:
          - buffers,loops
          - lifecycle,files,positions,notes
          - effects,voices
          - mix,variation,grains,structure,performance
          - modulation,freeze
          - memory,rings
          - record,waveform
```
A new area joins by adding its name to one item (or a new item); `docs_test.lua:1103-1132` requires every non-on-demand area file in exactly one shard and every shard name to have a file. Comment rules in the workflow: memory shares no shard with an area that builds a high engine; each shard runs under `timeout 600` with `ENGINE_CHECK_TIMEOUT=570`. The comment's "Area times on SuperCollider 3.13 at 3.5.0" line is summed by `structure_test.lua:3056-3079` and must match "about N minutes" in `AGENTS.md`, `docs/checks.md`, `docs/notes/test-harness/engine-check-runner.md`, `docs/notes/engine/structure.md` and `test/run_engine_check.sh` (today 1165 s, "about 19 minutes"): adding new areas' times there changes all five.

### `voiceOn` (`lib/engine/StrataVoices.sc:79-117`), whole

```
this.addCommand(\voiceOn, "iffffff", { arg msg;
    var voice = msg[1].asInteger;

    if (this.validVoice(voice)) {
        voiceControls[voice] = Dictionary[
            \freq -> msg[2], \amp -> msg[3], \pan -> msg[4], \bend -> 1,
            \modBus1 -> silentBus.index, \modBus2 -> silentBus.index, \modBus3 -> silentBus.index,
            \modAmpAmt1 -> 0, \modAmpAmt2 -> 0, \modAmpAmt3 -> 0,
            \modFreqAmt1 -> 0, \modFreqAmt2 -> 0, \modFreqAmt3 -> 0
        ];
        grainControls[voice].putAll(Dictionary[
            \grainSize -> msg[5], \grainDensity -> msg[6], \pitchShift -> msg[7]
        ]);
        this.resetOwnNote(voice);
        context.server.makeBundle(nil, {
            this.setSynth(this.voiceMixKey(voice), *this.controlPairs(\strataVoiceMix, voiceControls[voice]));
            this.areaCall(\gateVoice, voice);
        });
    };
});
```
(comments removed). A stopped voice becomes running inside `gateVoice` (`StrataLifecycle.sc:140-192`): `synths[voiceKey]`/`synths[grainKey]` are filled from `releasingSynths` or started (`:158-184`). `voiceRunning { arg voice; ^synths[this.voiceKey(voice)].notNil or: { synths[this.grainKey(voice)].notNil } }` (`StrataUtil.sc:32-34`) is false for a stopped or released voice, so "was stopped" must be read before the bundle. The stage (`voiceMix<n>`) is persistent (an `effectKeys` node), not part of this test.

### `retrigger` (`StrataVoices.sc:128-135`), whole

```
this.addCommand(\retrigger, "if", { arg msg;
    var voice = msg[1], velocity = msg[2].clip(0, 1);
    if (this.validVoice(voice)) {
        this.setSynth(this.voiceKey(voice), \velocity, velocity, \t_trig, 1);
        this.setGrainSynths(voice, \t_trig, 1);
        if (this.voiceRunning(voice)) { this.setSynth(this.voiceMixKey(voice), \velocity, velocity, \t_trig, 1) };
    };
});
```
It runs on a stopped voice too (each `setSynth` finds nothing); only the stage send checks `voiceRunning`.

### `openStepGate` (`lib/engine/StrataNotes.sc:390-392`), whole, and its one caller

```
openStepGate { arg voice;
    this.setSynth(this.voiceMixKey(voice), \t_gate, 1);
}
```
Called only at the end of `extraNoteOn` (`StrataNotes.sc:382`): `if (record[\state] == \live) { this.openStepGate(voice) };` (a live slot re-pitched, a releasing slot restarted, an empty slot started; not for a refused start). The engine's own restarts (`restartNotes`, `notesUnfrozen` → `startNote`) never call it.

### `delayMaxSeconds` (0c) sites

The literal 2 appears twice in `\strataDelay` (`StrataEffects.sc:154`): `DelayC.ar(..., 2, time.lag(0.1).clip(0.01, 2))`. The check-only 3.0 copy has its own literal (`test/engine_check/effects.scd:100`). See §0 item 1 for the stub constraint.

---

## 2. The grain reader (1a)

### `\strataGrainBuf` (`lib/engine/StrataGrainDefs.sc:144-174`), whole

```
SynthDef(\strataGrainBuf, {
    arg out, gate=1, bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0,
    grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
    envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
    modBus1=0, modBus2=0, modBus3=0,
    modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
    history=0, ringLevel=1, freeze=0, freezeMode=0,
    reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
    interval1=0, interval2=0, interval3=0, interval4=0,
    interval5=0, interval6=0, interval7=0, interval8=0,
    intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
    loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0,
    noteGate=1, noteBend=1, noteAmp=1, notePos=0, noteSize=0, velocity=1, t_accent=0;
    var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
    var fastModIn = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index);
    var m = this.fastModRead(fastModIn);
    var controls = (
        out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
        posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
        t_trig: t_trig, bend: bend, kill: kill, pan: pan, rateLevel: rateLevel,
        modBuses: [modBus1, modBus2, modBus3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
        ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
        sizeJitter: sizeJitter,
        intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
        intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
        fastMod: m, noteRate: 1, noteSize: noteSize, noteBend: noteBend,
        noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent
    );
    this.grainBody(controls, this.areaCall(\slotGrainReader, bufnumL, bufnumR, bufFrames, bufRateScale, this.fastModPosition(bufPos, m, notePos),
        bufRate, bufScan, posSpread, freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus));
}).add;
```
- The arg list must stay a literal `arg ...;` (the stub reads controls and numeric defaults from it, `norns_stubs.lua:448-461`; a named control like `\recHeadBus.kr` is invisible to the stub, so Lua could not `setGrainParam` it). `\strataGrainRing` (:103-132) has the same list with `bufL, bufR, phaseBus` and `noteRate=1`.
- `grainSignal` (:211-251) is where the reader's `level` and the note gain multiply into the fade: `fade: env * read[\level] * c[\ringLevel].lag(0.05) * this.notePark(...) * (c[\noteAmp].lag(this.noteLag) * (1 + this.voiceAccent(c[\t_accent], c[\velocity]))).clip(0, 2)` (:249-250); `grainBody` (:255-258) has the one `Out.ar`.

### `slotGrainReader` (`StrataGrainDefs.sc:326-350`), whole

```
slotGrainReader { arg bufnumL, bufnumR, bufFrames, bufRateScale, bufPos, bufRate, bufScan, posSpread,
    freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus;
    ^{ arg trig, rate, dur, mode;
        var serverScale = BufRateScale.kr(bufnumL);
        var slotRate = rate * bufRate * (bufRateScale / serverScale);
        var validFrames = Gate.kr(bufFrames, bufFrames > 0);
        var frameRate = slotRate * serverScale;
        var readRate = frameRate.abs.max(0.001);  // never 0: the duration divides by it
        var grainDur = dur.min((validFrames - grainEndMargin).max(0) / (readRate * SampleRate.ir));
        var grainFrames = grainDur * SampleRate.ir * readRate;
        var scanPhase = this.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_scanReset);
        var spreadDraw = TRand.ar(posSpread * -0.5, posSpread * 0.5, trig);
        var start = this.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, frameRate, grainFrames, validFrames,
            loopStart, loopLength, recHeadBus);
        (bufL: bufnumL, bufR: bufnumR, rate: slotRate, dur: grainDur,
            pos: start * (validFrames / BufFrames.kr(bufnumL)),
            level: (bufFrames > 0).lag(0.05))
    }
}
```
(comments removed). `rate` arrives already quantized and bent (`grainRate`, `StrataVariation.sc:35-50`), so a factor on `slotRate` is "after the quantize". `slotScanPhase` (`StrataPositions.sc:29-31`) and `slotGrainPos` (`StrataLoop.sc:46-61`) are quoted in E §1. `slotGrainReader` is in `AREA_CALL_METHODS`.

### The notes area's pieces (`lib/engine/StrataNotes.sc`)

- `perNoteGrainControls` (:190-195):
  ```
  perNoteGrainControls { arg voice;
      var names = [\noteGate, \noteBend, \noteAmp, \notePos, \noteSize, \noteRate, \velocity, \t_accent];
      if (grainSource[voice] == this.inputSource) { ^names ++ [\pitchShift] };
      if (grainSource[voice].inclusivelyBetween(1, numBuffers)) { ^names ++ [\bufRate, \scaleNote] };
      ^names
  }
  ```
  Used by `setGrainSynths` (:200-208) to strip per-note names from voice-wide sends to extra notes.
- `engineOwnedControls` (`lib/engine/StrataVoices.sc:285-289`):
  ```
  engineOwnedControls {
      ^#[\out, \gate, \kill, \t_trig, \velocity, \bufnumL, \bufnumR, \bufFrames, \bufRateScale, \recHeadBus,
          \bufL, \bufR, \phaseBus, \ringLevel, \rateLevel, \envBuf, \fastModIn,
          \noteGate, \noteBend, \noteAmp, \noteMain, \notePos, \noteSize, \noteRate, \t_accent, \t_gate]
  }
  ```
  Read at alloc into `refusedVoiceParams`/`refusedGrainParams` (`StrataVoices.sc:51-53`) and by the stub (`engine_method_symbols(source, "engineOwnedControls")`, `norns_stubs.lua:529`), which removes them from `grain_params`.
- `noteRecord { arg voice, slot; ^areaState[\notes][\slots][voice][slot] }` (:86). Fields from `emptyNoteRecord` (:80-84):
  ```
  if (slot == 0) { ^(expression: this.neutralNoteExpression, parked: false, rate: 1) };
  ^(state: \empty, synth: nil, cutting: nil, kind: nil, note: 60, freq: 440, rate: 1, velocity: 1,
      expression: this.neutralNoteExpression, order: 0, cutOrder: 0)
  ```
  `neutralNoteExpression { ^(bend: 1, amp: 1, position: 0, size: 0, main: 0) }` (:71). `stopNotes` (:564-570) rebuilds every record; `resetOwnNote` (:461-466), called by `voiceOn` before `gateVoice` (`StrataVoices.sc:104`), resets slot 0's `parked`, `expression` and `rate`.
- `startNoteSynth` (:224-237):
  ```
  startNoteSynth { arg voice, slot, silent = false;
      var record = this.noteRecord(voice, slot), kind = this.noteKindFor(voice), defName, notePairs;
      record[\kind] = kind;
      notePairs = this.notePitchPairs(voice, record)
          ++ (if (silent) { [\velocity, record[\velocity]] } { this.noteAccentPairs(record) }) ++ [\noteGate, 1]
          ++ this.noteExpressionPairs(kind, record[\expression]);
      if (kind == \voice) {
          defName = voiceSynthDefs[voice];
          ^this.watchNoteSynth(voice, slot, Synth(defName,
              [\out, granBuses[voice]] ++ this.controlPairs(defName, voiceControls[voice]) ++ notePairs, voiceGroup, \addToHead))
      };
      ^this.startGrainSynth(voice, if (kind == \stream) { processGroup } { this.voiceMixGroup(voice) }, \addToHead, notePairs,
          { arg synth; this.areaCall(\watchNoteSynth, voice, slot, synth) })
  }
  ```
  The note's pairs are last in `startGrainSynth`'s args (`StrataLifecycle.sc:79`), so they win over `grainControlPairs`.
- `extraNoteOn` (:363-383):
  ```
  extraNoteOn { arg voice, slot, note, freq, rate, velocity;
      var record = this.noteRecord(voice, slot);
      this.forgetFailedNoteStarts(record);
      if (this.voiceRunning(voice).not) {
          ^this.postFastModIgnored(\noteOn, "voice % is stopped".format(voice))
      };
      record[\note] = note;
      record[\freq] = freq;
      record[\rate] = rate;
      record[\velocity] = velocity;
      switch (record[\state])
      { \live } {
          this.sendToSynth(record[\synth].setMsg(*(this.notePitchPairs(voice, record) ++ this.noteAccentPairs(record))));
      }
      { \releasing } {
          this.cutNote(voice, slot);
          this.startNote(voice, slot);
      }
      { this.startNote(voice, slot) };
      if (record[\state] == \live) { this.openStepGate(voice) };
  }
  ```
  The `\live` branch (:374-376) is where a live slot's one-shot restart would ride.
- `ownNoteOn` (:498-507):
  ```
  ownNoteOn { arg voice, rate, velocity;
      var own = this.noteRecord(voice, 0);
      own[\parked] = false;
      this.ownNoteGateKeys(voice).do({ arg key;
          if ((key == this.grainKey(voice)) and: { this.frozenSynthVoice(voice) }) {
              own[\rate] = rate;
              this.setSynth(key, \noteGate, 1, \noteRate, rate, \velocity, velocity, \t_accent, 1);
          } { this.setSynth(key, \noteGate, 1) };
      });
  }
  ```
- `noteExpressionPairs` (:162-166):
  ```
  noteExpressionPairs { arg kind, expression;
      var pairs = [\noteBend, expression[\bend], \noteAmp, expression[\amp]];
      if (kind == \voice) { ^pairs ++ [\noteMain, expression[\main]] };
      ^pairs ++ [\notePos, expression[\position], \noteSize, expression[\size]]
  }
  ```
- `notePitchPairs` (:145-152):
  ```
  notePitchPairs { arg voice, record;
      ^switch (record[\kind])
      { \voice } { [\freq, record[\freq]] }
      { \buffer } { [\bufRate, record[\rate], \scaleNote, this.noteScaleNote(voice, record[\rate])] }
      { \input } { [\pitchShift, record[\rate]] }
      { \stream } { [\noteRate, record[\rate]] }
      { [] }
  }
  ```
- `extraNoteExpression` (:405-411) keeps the expression on the record and sets a live or releasing synth; `ownNoteExpression` (:532-536) keeps slot 0's and sets `ownNoteKey`'s synth. `ownNotePairs` (:448-457) is what the own grain synth starts or is re-gated with (`startGrainSynth` :79 when `notePairs` is nil; `gateVoice` :181-182): `noteGate`, `noteBend`, `noteAmp`, `noteMain`, `notePos`, `noteSize`, `noteRate` from slot 0's record.
- `absoluteNoteRate` and `leaveStream` (:25-43):
  ```
  noteRateRootNote { ^60 }
  absoluteNoteRate { arg note;
      ^(2 ** ((note - this.noteRateRootNote) / 12)).clip(0.25, 4)
  }
  leaveStream { arg record;
      if (record[\kind] == \stream) { record[\rate] = this.absoluteNoteRate(record[\note]) };
  }
  ```
  `leaveStream` is called by `notesUnfrozen` (:485) and `restartNotes` (:550). `docs_test.lua:2142-2145` pins `noteRateRootNote` = `S.lib.notes.NOTES.rate_root_note` = `S.lib.midi_in.MIDI.rate_root_note` (60).
- The command validation pattern for new commands: `addNoteCommands` (:585-636), e.g. `noteOn` (:594-602):
  ```
  this.addCommand(\noteOn, "iiffff", { arg msg;
      var voice = msg[1], slot = msg[2], note, freq, rate, velocity;
      if (this.fastModIndicesValid(\noteOn, [[\voice, voice, lastVoice], [\slot, slot, lastSlot]])
          and: { this.fastModValuesFinite(\noteOn, [[\note, msg[3]], [\freq, msg[4]], [\rate, msg[5]], [\velocity, msg[6]]]) }) {
          note = msg[3].clip(0, 127); freq = msg[4].clip(8, 20000); rate = msg[5].clip(0.25, 4); velocity = msg[6].clip(0, 1);
          this.receiveNote(\noteOn, [voice, slot, note, freq, rate, velocity]);
          if (slot > 0) { this.areaCall(\extraNoteOn, voice, slot, note, freq, rate, velocity) } { this.ownNoteOn(voice, rate, velocity) };
      };
  });
  ```
  `receiveNote` (:573-575) records in `areaState[\notes][\received]`. The notes area today has no `grainParamHandlers`.

### Slot plumbing (`lib/engine/StrataLifecycle.sc`, `StrataBuffers.sc`)

- `bufferSlotPairs` (`StrataLifecycle.sc:93-97`):
  ```
  bufferSlotPairs { arg voice;
      var slot = grainSource[voice] - 1;
      if (grainSource[voice].inclusivelyBetween(1, numBuffers).not) { ^[] };
      ^[\bufnumL, buffersL[slot].bufnum, \bufnumR, buffersR[slot].bufnum] ++ this.slotLengthPairs(slot)
  }
  ```
- `slotLengthPairs` (:102-106):
  ```
  slotLengthPairs { arg index;
      var frames = bufferFrames[index];
      var head = [\recHeadBus, this.slotHeadBus(index).index];
      ^(if (frames > 0) { [\bufFrames, frames, \bufRateScale, this.bufferRateScale(index)] } { [\bufFrames, 0] }) ++ head
  }
  ```
  Callers: `bufferSlotPairs` (synth start, `startGrainSynth` :78; re-gate, `gateVoice` :181) and `bufferChanged` (live readers).
- `bufferChanged` (`StrataBuffers.sc:191-203`):
  ```
  bufferChanged { arg index;
      var live = numVoices.collect({ arg voice; [synths[this.grainKey(voice)]] ++ this.noteSynths(voice, \grain) }).flatten, seconds;
      this.slotGrainSynths(index).do({ arg synth;
          if (live.includes(synth)) {
              this.sendToSynth(synth.setMsg(*this.slotLengthPairs(index)));
          } {
              if (bufferFrames[index] == 0) { this.sendToSynth(synth.setMsg(\bufFrames, 0)) };
          };
      });
      seconds = this.bufferStateSeconds(index);
      areaState[\buffers][\announced][index] = seconds;
      bufferStatePoll.update(this.bufferStateReport(index, seconds));
  }
  ```
  `slotGrainSynths(index)` (:207-211) iterates `grainSlots` (every `\strataGrainBuf` until it frees, `StrataLifecycle.sc:82`).
- Per-slot engine state lives in class variables allocated by the buffers area (`allocBufferState`, `StrataBuffers.sc:30-50`: `bufferFrames`, `bufferSampleRates`, `slotChanges`, `bufferLoads`) and in `areaState[\buffers]`; a new per-slot array would go in an area's `areaState` (no new class variable allowed).
- **Load taking effect**: `applyLoad` (`StrataBuffers.sc:299-347`). The reset block, at the command's apply, before the fade:
  ```
  this.stopRecording(index);
  change = this.slotChanged(index, load);
  bufferFrames[index] = 0;
  bufferSampleRates[index] = context.server.sampleRate;
  this.bufferChanged(index);
  ```
  (:301-308); the success branch after the server's read (:336-342) sets `bufferSampleRates[index] = sampleRate`, `storeSlotPeaks`, then `writeSlotPeaks(index, frames, { bufferFrames[index] = frames; this.bufferChanged(index) })`. A failed read (:327-334) resets the rate, clears the peaks and calls `bufferChanged`.
- **Clear**: `clearSlot` (`StrataBuffers.sc:408-421`), reset lines :411-416:
  ```
  this.stopRecording(index);
  change = this.slotChanged(index);
  bufferFrames[index] = 0;
  bufferSampleRates[index] = context.server.sampleRate;
  this.clearSlotPeaks(index);
  this.bufferChanged(index);
  ```
- **Recordings** (`lib/engine/StrataRecord.sc`): every kind enters `recordSlot` (:395-438, the `recordBuffer` command through `areaCall`, :148-150), whose common reset is :409-410 (`this.stopRecording(index); change = this.slotChanged(index);`) at the command, before any delay. Then:
  - `prepareTake` (:446-462): a replace take sets `bufferFrames 0`, the server rate and `bufferChanged` (:448-452) at once or, for a synced take, `bufferFadeWait + recordPrepMargin` before its start (scheduled at :433-436, guarded by `slotChanges`); a replace or empty-slot take zeroes after `afterSlotFade` and forks `startTake` after a sync (:453-460), else `startTake` at once (:461).
  - `startTake` (:471-484) and `sendTake` (:492-519): the record synth is created (paused until a timestamp when delayed, :510-512) in the tap group.
  - `takeArmed` (:533-548): the record synth's arming reply (after a threshold or the timestamp); a playable recording's length becomes `max(V, D)` here (:538-545).
  - `endTake` (:635-658): the take ended and kept (peaks read, length reported, "ended", scratch write).
  These are the candidate lines for "the start of every recording" resetting a slot gain; which one is the design's moment is the planner's call (the command, the synth's send, or the arming).
- `slotRecording { arg index; ^recordSynths[index].notNil or: { stopReplies[index].notNil } }` (:314-316).

### Engine checks the change touches: names that pin behavior a default must keep

- **positions** (`test/engine_check/positions.scd`): "positions: slotScanPhase is 3.2's scan" (:46-48, the hook beside `Phasor.ar(t_phaseReset, rate * SampleDur.ir, 0, 1)` in `\strataCheckScanCompare`, :23-27, which calls `engine.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_phaseReset)` with five arguments); "positions: t_scanReset restarts the phase and is not stored" (:105-112); "positions: scrubRate adds to the scan" (:125-127); "positions: scanHold stops the scan but not the glide" (:145-148); "positions: scrubRate and scanHold survive a source switch" (:156-157); "positions: the scan controls feed a UGen" (:160-161, `h.controlFeedsAUGen`).
- **loops** (`test/engine_check/loops.scd`): `\strataCheckLoopStarts` (:34-53) and `\strataCheckLoopAlternating` (:60-76) call `engine.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, rate, durFrames, validFrames, loopStart, loopLength, recHead)` (10 arguments); `\strataCheckLoopReverse` (:81-88) calls `engine.slotGrainReader(...)` with 15. Names: "loops: grains start inside the region" (:121), "loops: bufPos, scan and spread wrap inside the loop" (:134), "loops: bufPos 1 alone starts at the loop's last start" (:149), "loops: a grain may play past the loop end but never past the valid region" (:166), "loops: a loop shorter than a grain never reads past the valid region" (:182, :290), "loops: loopStart 0 and loopLength 1 give 3.1's positions" (:193, within 1e-5), "loops: a grain whose direction or length differs ... starts inside its own range" (:209), "loops: no control-rate Clip in % reads an audio-rate bound" (:213-219), "loops: loopStart and loopLength reach a UGen in strataGrainBuf" (:220-221), "loops: strataGrainBuf's loop defaults are the whole region" (:222-224), "loops: reverse grains in a slot never read the zeroed tail" (:354).
- **lifecycle** (`test/engine_check/lifecycle.scd`): "lifecycle: a new grain synth's scan starts at 0" (:717), "lifecycle: a re-gated buffer voice restarts its scan" (:728), "lifecycle: a voiceOn on a running buffer voice keeps its scan" (:738).
- **notes** (`test/engine_check/notes.scd`): "notes: the four commands exist with their signatures" (`checkSignatures`, :169-173, a fixed list of four); "notes: with the pool empty no command creates a node" (:199-200); "notes: each command records its arguments, the continuous ones clipped" (:234-236); "notes: out-of-range indices and non-finite values are ignored, one line each" (:269-273, lines must begin `"strata: <command> ignored: "`); "notes: noteOn on a live slot sets its pitch, fires its accent and creates no node" (:333-338); "notes: a voice-wide grain param reaches every note of the voice, and bufRate only its own note" (:450); "notes: noteExpression is kept for an empty slot and a later noteOn starts with it" (:481); "notes: a buffer load fades every note reading the slot" (:912); "notes: a source switch under a chord cuts every extra note and restarts the held ones" (:881); ruling 53's "each note's ... on the server" (:1279); ruling 54's gate checks (:1363, :1368); "notes: a slot-0 noteOn on an unfrozen voice only unparks it" (:1400).
- **grains** (`test/engine_check/grains.scd`): "grains: both grain defs play 3.4's values with the note controls at their defaults" (:202-209, every control in `noteNeutral` (:134) at its neutral default); "grains: both grain defs declare every 3.2 control" (:351-359); "grains: the hook methods exist" (:362-363, list `[\grainRate, \grainPan, \grainDur, \slotGrainPos, \scanRate, \ringScanOffset, \freezeVoice, \unfreezeVoice, \voiceOutput, \voiceFilter]`); "strataGrainBuf has a bufRateScale control" (:346-347).
- **modulation**: "modulation: with every bus at 0 each grain synth and stage equals 3.3's within 1e-6" (`checkEqual33`, :1220-1270, using `\strataCheckGrainBuf33`, :173-192, which calls the engine's `slotGrainReader` with 15 arguments at :190-191).
- **mix**: `\strataCheckGrainBuf32Split` (:70-75, the engine's `slotGrainReader` with 15 named controls); "mix: a buffer voice equals 3.2's within 1e-6 in steady state, with crossmod, accents and an amp move" (:598), "mix: bypassed, a buffer voice and an input voice equal a verbatim copy of 3.2's grain defs within 1e-6" (:663).
- **structure**: "structure: both grain defs declare recHeadBus, scrubRate, scanHold and t_scanReset" (:381-384); "structure: a triggered buffer grain with spreads 0 matches 3.2's within 1e-6" (:399-431, `\strataGrainBuf` beside `h.def32[\grainBuf]`, `\strataCheckBusDiff`).
- **buffers**: "a clear leaves the rate of the grains fading out" (:328), "a recording leaves the rate of the grains fading out until its take is in" (:333), "the take's rate arrives with its length" (:336); the `bufFrames 0` fade checks (:237, :275-311).
- **record**: "record: a playable recording keeps the slot playing and sets its length to max(V, D) at its start" (:829-846), "record: a canceled armed recording leaves the slot as it was" (:861-872), "record: a playable recording into an empty slot zeroes it after the fade" (:874-890), "record: the periodic bufferState never announces an arming's length before its peaks file" (:980).
- **memory**: "memory: each grain synth takes under 88 KB of the pool" (:139-142).

### Check-only copies of earlier defs: how they are compared

- Runner (`test/engine_check.scd:81-283`): `addDefs32` builds `\strataCheckRecord32`, `\strataCheckGrainRing32`, `\strataCheckGrainBuf32` from verbatim 3.2 text (`slotGrainPos32` :125-134, `slotGrainReader32` :154-171 with its own `Phasor.ar(0, e.scanRate(bufScan, freeze) * SampleDur.ir, 0, 1)`, `grainBody32` :172-203), exposed as `h.def32` (:892-894: `(record: \strataCheckRecord32, grainRing: \strataCheckGrainRing32, grainBuf: \strataCheckGrainBuf32)`). They call only the engine's stable helpers (`openedGate`, `killFade`, `panBalance`, `grainRate`, `grainDur`, `grainPan`, `scanRate`, `ringScanOffset`, ring constants).
- Comparison pattern: two synths started in one bundle on two buses, `\strataCheckBusDiff` or a def-local diff, read with `h.measure`/`measureFor` (`modulation.scd:270`), passing on `difference < 1e-6` with `level > 0.01` (e.g. `modulation.scd:1260`). grains.scd's helpers: `notePair(defName, argsA, argsB, scale, defNameB)` (:180-191), `pairMatches(pair, tolerance = 1e-6)` (:194), `noteBufArgs` (:144-149), `\strataCheckNoteDiff` with a `scale` control (:165-168: compares `a` with `b × scale × (1 + accent)`, the shape for a gain check), `controlDefault`.
- `h.controlFeedsAUGen(defName, controlName)` (`test/engine_check.scd:391-396`, on `h` at :919): true when a UGen reads the control.

### The memory area (`test/engine_check/memory.scd`)

- Measurement: `floodFit` (:73) floods `floodCount = 640` small probes (`\strataCheckPoolProbe`, 240 controls, :750-753) and counts those created; `smallProbeKB` (:78-85) calibrates against four 256 KB `DelayN` probes; `sizeOf = { arg start; ... (before - after) * probeKB / count }` with `count = 20` (:170-177). The grain defs' sizes: `checkGrainSynthSizes` (:108-163), twenty synths each at grain size 0.5, density 200; the check line (:139-142):
  ```
  check.(sizes.every({ arg size; (size > 0) and: { size < 88 } }),
      "memory: each grain synth takes under 88 KB of the pool (% KB, by allocation probes; 3.2's copies, with their filter and sends: % KB)".format(...));
  ```
  The stage: forty stages, `< 42` (:150-161).
- Per-def limits are declared in the check as literals or tables: grain defs `88` (:139), stage `42` (:160), record `24` and head guard `8` (:198-202), `modulationLimitsKB = (lfo: 9, strataScatter: 45, strataFastOffsets: 13.5)` (:214), `voiceDefLimitsKB` (:249-250). The notes' list of them is `docs/notes/engine/memory.md`, Must not break (lines 3-12).
- Worst cases: `checkMemoryWorstCase = { arg target, probeCount, floorLabel, engage; ... }` (:346-706), run as `checkMemoryWorstCase.(engine, 12, "3 MB")` (:777) and, on a high engine, `checkMemoryWorstCase.(high, 14, "3.5 MB", { spectral freeze })` (:736-740). Modulation runs through every case (`startModulation`, :358-361: six engine LFOs smooth/drunk at 20 Hz and scatter on every voice). One case, the spaced mixed worst case (:514-523):
  ```
  startAll.value;
  server.sync; 0.2.wait;
  sourceSteps.do({ arg sourceOf, step;
      if (step > 0) { 0.2.wait; server.sync };
      // the last switch makes the cutting set the probes must meet
      if (step == (sourceSteps.size - 1)) { holdVoices.value };
      switchAll.(sourceOf);
  });
  target.numVoices.do({ arg voice; command.(\voiceOff, voice) });
  startAll.value;
  engage.value(command);
  probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted");
  ```
  `probeHeadroom(label, scenario, count, report, cutBound)` (:439-506) sends `count` 256 KB probes, floods, checks every probe allocated, and records `[tier, label, modulationNodes]` (:478). Floors: twelve probes standard, fourteen high (eight cases), twelve on both with eight recordings (:618-622, gathered at :782-784), five probes (1280 KB) for the two pool cases (:645-658 all-buffer pool, 53 `\strataGrainBuf` asserted :655; :681-698 synth -> buffer -> synth pool, counts `[23, 14, 30, 9]` asserted :695).
- `modulationRunning` must be 20 entries of `[6, 1, 1]` (:779-781); `modulationNodes` counts names beginning `strataFastLfo`, `== \strataScatter`, `== \strataFastOffsets` in `fastModGroup` (:366-370).

---

## 3. Onsets (1b)

### `writeSlot`'s first stage (`lib/engine/StrataFiles.sc:268-373`)

```
writeSlot { arg index, path, done, start = 0, length = 1;
    var valid = bufferFrames[index];
    var sampleRate = bufferSampleRates[index];
    var firstFrame, frames, generation, tempPaths, partPath;
    if (valid < 1) { ... done.value(false); ^this };
    firstFrame = (start.clip(0, 1) * valid).round.asInteger;
    frames = ((start + length).clip(0, 1) * valid).round.asInteger - firstFrame;
    ...
    path = path.standardizePath;
    writeCount = writeCount + 1;
    generation = writeCount;
    writeGenerations[path] = generation;
    tempPaths = ["L", "R"].collect({ arg side;
        Platform.defaultTempDir +/+ "strata-buf%-%-%-%.wav".format(index + 1, instanceTag, generation, side)
    });
    partPath = path ++ "." ++ instanceTag ++ "-" ++ generation ++ ".part";
    buffersL[index].write(tempPaths[0], "wav", "float", frames, firstFrame);
    buffersR[index].write(tempPaths[1], "wav", "float", frames, firstFrame);
    fork({
        ...
        try {
            context.server.sync;
            written = current.value and: {
                this.interleaveFiles(tempPaths, partPath, sampleRate, current, frames, openFiles)
            };
            tempPaths.do({ arg tempPath; File.delete(tempPath) });
            ...
```
(:268-311). The wait for the server's writes is `context.server.sync` inside a `fork(..., SystemClock)` (:294, :307). `writeCount` and `writeGenerations` are class variables (`Engine_Strata.sc:74-75`). On an sclang error the routine closes `openFiles`, deletes the temp files (:355-371).

### `interleaveFiles`' chunk loop (`StrataFiles.sc:416-425`)

```
while { finished and: { left = this.freshReadArray(chunkFrames); sources[0].readData(left); left.size > 0 } } {
    right = this.freshReadArray(chunkFrames);
    sources[1].readData(right);
    // the last chunk is shorter: its own keys
    if (left.size != keys[0].size) { keys = this.interleaveKeys(left.size) };
    output.writeData(this.interleaveChunk(left, right, keys, int16Peak));
    // from the real time: a long save's chunks outlast a 1 ms wait
    this.yieldToCommands(writeChunkWait);
    finished = keepGoing.value;
};
```
`chunkFrames = 8192` (:392). Sources opened with `SoundFile.openRead` and added to `openFiles` (:395, :399).

### Helpers

- `freshReadArray { arg size; ^Signal.newClear(size) }` (:139-141).
- `yieldToCommands { arg wait; wait.max((Main.elapsedTime - thisThread.seconds) + this.commandGap).wait }` (:176-178); `commandGap { ^0.0002 }` (:183).
- `renameIntoPlace { arg partPath, path, finish; ... }` (`lib/engine/StrataWaveform.sc:221-258`): `finish.(written)` once, through the mover or `renameBySubprocess`; the mover's backlog is 4 (`peaksMoverBacklog`, :127), shared with peaks, saves and scratch takes.

### `writeSlotPeaks` and `writePeaksFile`, whole (the pattern for a second file)

```
writeSlotPeaks { arg index, frames, action, current;
    var state = areaState[\waveform], change = slotChanges[index], path = this.peaksPath(index).standardizePath;
    var generation, partPath, content = this.peaksContent(index, frames);
    var finish = { arg written;
        if (written.not) { postln("strata: cannot write " ++ path) };
        state[\written][index] = if (written) { content };
        if (current.notNil) { if (current.value) { action.value } } {
            if (slotChanges[index] == change) { action.value }
        };
    };
    state[\generation] = state[\generation] + 1;
    generation = state[\generation];
    partPath = path ++ "." ++ instanceTag ++ "-" ++ generation ++ ".part";
    if (this.writePeaksFile(index, content, generation, partPath).not) { ^finish.(false) };
    // mv -f would move the file into a folder at the path, and succeed
    if (PathName(path).isFolder) { File.delete(partPath); ^finish.(false) };
    this.renameIntoPlace(partPath, path, finish);
}
```
(`StrataWaveform.sc:70-87`)
```
writePeaksFile { arg index, content, generation, path;
    var text = "strata-peaks 1\nslot %\n".format(index + 1) ++ content[0] ++ "generation %\n".format(generation)
        ++ content[1] ++ "\n";
    var file;
    try { File.mkdir(path.dirname) };
    ^try {
        file = File.new(path, "w");
        if (file.isOpen) { file.write(text); file.close; true } { false }
    } { false }
}
```
(:297-306). `peaksPath { arg index; ^this.allocSettingsDirectory +/+ ("buf" ++ (index + 1) ++ ".peaks") }` (:42-44); `allocSettingsDirectory` is the performance area's (`StrataPerformance.sc:43-46`). `peaksContent` (:282-285) builds its value list with `collect` and `join`, one function call per value (64).

### `deleteStaleParts` (`StrataFiles.sc:202-222`)

```
deleteStaleParts {
    var oldest = Date.getDate.rawSeconds - stalePartAge, unreadable = List.new;
    var patterns = this.stalePartDirs.collect({ arg dir; dir +/+ "*.part" })
        ++ [Platform.defaultTempDir +/+ "strata-buf*-*.wav"];
    patterns.do({ arg pattern;
        pattern.pathMatch.do({ arg path;
            var modified = try { File.mtime(path) } { ...; nil };
            if (modified.notNil and: { modified < oldest }) { File.delete(path) };
        });
    });
    ...
    ^unreadable.asArray
}
```
`stalePartDirs` (:231-243) = scratchDir, its parent and the settings folder. Called from the files area's `allocState` (:14-20). So a `buf<n>.onsets.<tag>-<g>.part` in the settings folder is swept already; a temp float file is swept only if its name matches `strata-buf*-*.wav` in `Platform.defaultTempDir` (a different name needs a pattern here, in the files area's file).

### A poll: `bufferSaveResult`, whole

- Added in the files area's `addCommands` hook (`StrataFiles.sc:39-41`):
  ```
  areaState[\files][\saveResultPoll] = this.addPoll(\bufferSaveResult, {
      this.bufferSaveResultPoll.value ? 0.0
  }, false);
  ```
  `bufferSaveResultPoll { ^areaState[\files][\saveResultPoll] }` (:44). `addPoll` is the engine's override (`StrataUtil.sc:200-204`).
- Encoding (`StrataFiles.sc:60-62`):
  ```
  bufferSaveResultValue { arg index, save, failed;
      ^((((save * 2) + failed.binaryValue) * numBuffers) + index).asFloat
  }
  ```
  Keep it on one line `name { arg ...; ^expr }`: `docs_test.lua:245-309` (`engine_value_method`) parses that shape and evaluates it to feed Lua's handler (#459, test at :311).
- Update (`StrataFiles.sc:66-74`): `this.writeSlot(index, path, { arg written; this.bufferSaveResultPoll.update(this.bufferSaveResultValue(index, save, written.not)); }, start, length);`, with the count `this.bufferSaves[index] = save` (per slot, from 1, `areaState[\files][\saves]`, :15).
- The stub registers a poll for every `addPoll(\name` in the source (`norns_stubs.lua:226-232`, `make_poll` :2677-2690).

### `slotChanges` as a guard

`slotChanged` (`StrataBuffers.sc:398-404`) increments `slotChanges[index]` on every load taking effect, clear, record and stop. Pattern: read `change = slotChanges[index]` at the start, act later only `if (slotChanges[index] == change)` (`afterSlotFade` :382-388; `writeSlotPeaks` :71, :77; `readSlotPeaks` :316-318; the record steps). A long load's check also uses `loadsSuperseded` (`keepGoing` in `fileDecodes`, :116-119).

### The two structure tests that scan `fileDecodes`

- `"the engine's sample paths run no sclang function per sample (#131)"` (`structure_test.lua:1966-1989`). Banned text (`per_sample_loops`, :1220-1227): `"{%s*arg%s", "{%s*|", "%.do%s*%(", "%.collect%s*%(", "%.fill%s*%(", "%.select%s*%(", "%.reject%s*%(", "%.every%s*%(", "%.any%s*%(", "%.inject%s*%(", "%.sum%s*%(", "%.do%s*{", "%.collect%s*{"`. Scanned methods: `{ "interleaveChunk", "interleaveKeys", "fileDecodes", "freshReadArray" }` of `StrataFiles.sc` (:1977), and `interleaveFiles`' `while (cond) (body)` (:1983-1988).
- `"the peak scan allocates nothing per sample"` (:3104-3126). Banned text (`peak_scan_findings`, :3085-3094): `"%.abs", "[%s%(]abs%(", "copyRange", "collect", "maxItem", "minItem"`, `FloatArray.fill(n, {`, and stale reads. Scanned: `fileDecodes` and every `this.<name>` it calls that `StrataFiles.sc` defines (:3114-3120).
- Both read a method body with `sc_method_body(text, name)` (:1209-1216: the first `\n<ws>name<ws>{`, its `%b{}`, its `arg ...;` removed) and pick the file by path (`file.path:match("StrataFiles%.sc$")`). A third test for `StrataOnsets.sc` follows the same shape.
- Also applied to every engine file: `stale_reads` (:1178-1202, each `.readData(x)` needs `x = this.freshReadArray(` on its line or the one before) and `uses_local_buf` (:1160-1172).

### Lua side

- Poll registration (`lib/buffers.lua:1032-1057`, a start step at `S.constants.START_ORDER.buffer_polls`, 60, `lib/constants.lua:196`):
  ```
  S.buffer_polls.save_result = poll.set("bufferSaveResult", buffer_save_result)
  if S.buffer_polls.save_result then
    S.buffer_polls.save_result:start()
  else
    print("bufferSaveResult poll not found")
  end
  ```
  The polls are stopped at `CLEANUP_ORDER.buffer_polls` (130, `lib/constants.lua:280`).
- Handler (`lib/buffers.lua:641-664+`):
  ```
  function buffer_save_result(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
      or value ~= math.floor(value) then return end
    local slot = math.floor(value % NUM_BUFFERS) + 1
    local save_and_failed = math.floor(value / NUM_BUFFERS)
    local failed = save_and_failed % 2 == 1
    local save_number = math.floor(save_and_failed / 2)
    if not valid_buffer_slot(slot) then return end
    local buffer = S.buffers[slot]
    local found = nil
    for index, save in ipairs(buffer.pending_saves) do
      if save.number == save_number then found = index; break end
    end
    if not found then return end
    local save = table.remove(buffer.pending_saves, found)
    ...
    if save.number == buffer.saves_sent then  -- newest only: flash
  ```
  The send counts first (`send_save`, :548-554: `saves_sent + 1`, a bounded `pending_saves`).
- `lib/waveforms.lua`: `parse` (:51-72) and the clock loop (:183-211):
  ```
  local function parse(slot, text)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    if lines[1] ~= PEAKS_MAGIC then return nil end
    local fields = {}
    for index = 2, #lines do
      local key, rest = lines[index]:match("^(%a+)%s*(.*)$")
      if key then fields[key] = rest end
    end
    if tonumber(fields.slot) ~= slot then return nil end
    local frames, rate = tonumber(fields.frames), tonumber(fields.rate)
    if not frames or not rate or rate <= 0 then return nil end
    if math.abs(frames / rate - S.buffers[slot].seconds) > LENGTH_TOLERANCE then return nil end
    local values = {}
    for token in (fields.peaks or ""):gmatch("%S+") do
      local value = tonumber(token)
      if not value or value ~= value or value < 0 or value > 1 then return nil end
      values[#values + 1] = value
    end
    if #values ~= WAVEFORM_POINTS then return nil end
    return values
  end
  ```
  ```
  local function tick()
    mark_playable_recordings()
    for slot = 1, NUM_BUFFERS do
      if marked[slot] then
        marked[slot] = nil
        read(slot)
        return
      end
    end
  end
  ...
  S.register_start(S.constants.START_ORDER.waveforms, function()
    stop()
    M.read_clock = clock.run(function()
      while true do
        clock.sleep(1 / UI_PAGES.FRAMES_PER_SECOND)
        S.lib.ui_frame.contained_call(tick_errors, "tick", "peaks read", tick)
      end
    end)
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.waveforms, stop)
  ```
  `read(slot)` (:83-98) opens `peaks_path(slot)` = `S.lib.scenes.scene_data_dir .. "buf" .. slot .. ".peaks"` (:45-47), reads `*a`, parses. `parse`'s keys are letters only (`%a+`), so a key like `strengths` is fine and a digit in a key is not.

---

## 4. Envelope nodes (1c): the engine LFOs, the pattern to follow (`lib/engine/StrataModulation.sc`)

- Area hooks (:68-89): `allocState: { this.areaCall(\allocFastModulation) }`, `addDefs: { this.areaCall(\addFastModDefs); [] }`, `addCommands: { this.areaCall(\addFastModCommands) }`, `start: { this.areaCall(\startFastModulation) }`, `stop: { this.areaCall(\stopFastModulation) }`, `free: { this.areaCall(\freeFastModBuses) }`, `effectKeys: [this.fastOffsetsKey]`, plus the gate `grainParamHandlers`.
- `allocFastModulation` (:103-119): makes `fastModBus` (35 channels) and `silentFastModBus`, `state[\lfos] = Array.newClear(this.numFastLfos)`, `state[\scatter] = nil`, `state[\nodeChannels] = IdentityDictionary.new`, `state[\received] = IdentityDictionary.new`, `state[\stopped] = true`, and each voice's `fastModIn` block. A new area at order 190 runs after it, so `areaState[\modulation][\fastModGroup]` and `fastModBus` exist by its `start`/`allocState`; `fastModGroup` is made in the modulation `start` (:130-135) and freed in its `stop` (:139-146):
  ```
  stopFastModulation {
      var state = areaState[\modulation];
      state[\stopped] = true;
      state[\lfos] = Array.newClear(this.numFastLfos);
      state[\scatter] = nil;
      synths.removeAt(this.fastOffsetsKey);
      state[\fastModGroup] !? { arg group; group.free };
  }
  ```
  `free` runs descending, so an area at 190 stops before modulation (160) frees the group; its nodes would also go with the group.
  ```
  freeFastModBuses {
      var state = areaState[\modulation];
      [\fastModBus, \silentFastModBus].do({ arg name; state[name] !? { arg bus; bus.free } });
  }
  ```
- The LFO def builder (`addFastModDefs`, :245-258):
  ```
  this.fastLfoShapeNames.do({ arg name, shape;
      SynthDef(this.fastLfoDefName(shape), { arg out, rate = 0.25, depth = 0, offset = 0, t_sync = 0, syncPhase = 0, gate = 1;
          var phase = Phasor.kr(t_sync, rate * ControlDur.ir, 0, 1, syncPhase);
          var u = this.fastLfoShape(shape, phase);
          var env = EnvGen.kr(Env.asr(fade, 1, fade), this.openedGate(gate), doneAction: 2);
          Out.kr(out, ((((2 * u) - 1) * depth.lag(fade)) + offset) * env);
      }).add;
  });
  ```
  with `fade = this.fastLfoFadeSeconds` (0.02, :46). `fastLfoDefName { arg shape; ^("strataFastLfo" ++ this.fastLfoShapeNames[shape]).asSymbol }` (:41).
- `startFastLfo` (:309-322) and `watchFastLfo` (:338-342):
  ```
  startFastLfo { arg lfo, place, phase;
      var defName = this.fastLfoDefName(place[\shape]), group = areaState[\modulation][\fastModGroup], synth;
      if (phase.isNil) {
          synth = Synth(defName, place[\controls], group, \addToTail);
      } {
          context.server.makeBundle(nil, {
              synth = Synth(defName, place[\controls], group, \addToTail);
              this.sendToSynth(synth.setMsg(\syncPhase, phase, \t_sync, 1));
          });
      };
      place[\released] = false;
      this.anchorFastLfo(place, phase ? 0);
      ^this.areaCall(\watchFastLfo, lfo, synth, place[\channel])
  }
  watchFastLfo { arg lfo, synth, channel;
      areaState[\modulation][\nodeChannels][synth] = channel;
      synth.onFree({ this.fastLfoEnded(lfo, synth) });
      ^synth
  }
  ```
- `fastLfoEnded` (:351-363):
  ```
  fastLfoEnded { arg lfo, synth;
      var state = areaState[\modulation], channel = state[\nodeChannels].removeAt(synth), place;
      if (state[\stopped]) { ^this };
      place = state[\lfos][lfo];
      if (place.notNil and: { place[\synth] === synth }) {
          if (place[\running]) { place[\synth] = this.areaCall(\startFastLfo, lfo, place, this.fastLfoPhaseNow(place)) } {
              state[\lfos][lfo] = nil;
              channel !? { this.zeroFastModChannels(channel, 1) };
          };
      } {
          if (channel.notNil and: { place.isNil or: { place[\channel] != channel } }) { this.zeroFastModChannels(channel, 1) };
      };
  }
  ```
  Note: it zeroes a channel whenever this LFO no longer writes it, whatever another writer (another LFO, an envelope node) does on that channel; "Other writers on that channel write it again in the next block" (comment :350). The offset node writes every channel every block (E §4).
- `setFastLfo` (:377-417):
  ```
  setFastLfo { arg lfo, voice, destination, shape, rate, depth, offset;
      var state = areaState[\modulation], place = state[\lfos][lfo], channel = this.fastModChannel(voice, 0, destination);
      var controls = [\out, channel, \rate, rate, \depth, depth, \offset, offset], oldChannel, old, fresh, phase;
      if (state[\stopped]) { ^this };
      if (place.isNil) {
          place = (shape: shape, channel: channel, controls: controls, running: true);
          state[\lfos][lfo] = place;
          place[\synth] = this.areaCall(\startFastLfo, lfo, place);
          ^this
      };
      oldChannel = place[\channel];
      phase = this.fastLfoPhaseNow(place);
      place[\channel] = channel;
      place[\controls] = controls;
      this.anchorFastLfo(place, phase);
      if (shape != place[\shape]) {
          place[\shape] = shape;
          old = place[\synth];
          place[\synth] = if (place[\released].not) {
              this.anchorFastLfo(place, 0);
              this.areaCall(\watchFastLfo, lfo, Synth.replace(old, this.fastLfoDefName(shape), controls), channel)
          } {
              context.server.makeBundle(nil, {
                  this.sendToSynth(old.freeMsg);
                  fresh = this.areaCall(\startFastLfo, lfo, place);
              });
              fresh
          };
          place[\running] = true;
          if (oldChannel != channel) { this.zeroFastModChannels(oldChannel, 1) };
      } {
          place[\running] = true;
          state[\nodeChannels][place[\synth]] = channel;
          this.sendToSynth(*([place[\synth].setMsg(\gate, 1, *controls)]
              ++ (if (oldChannel != channel) { [['/c_fill', oldChannel, 1, 0]] } { [] })));
      };
  }
  ```
- `stopFastLfo` (:421-428):
  ```
  stopFastLfo { arg lfo;
      var place = areaState[\modulation][\lfos][lfo];
      if (place.notNil and: { place[\running] }) {
          place[\running] = false;
          place[\released] = true;
          this.sendToSynth(place[\synth].setMsg(\gate, 0));
      };
  }
  ```
- `syncFastLfo` (:433-438):
  ```
  syncFastLfo { arg lfo, phase;
      areaState[\modulation][\lfos][lfo] !? { arg place;
          this.anchorFastLfo(place, phase);
          this.sendToSynth(place[\synth].setMsg(\syncPhase, phase, \t_sync, 1));
      };
  }
  ```
- Validation (:517-545):
  ```
  postFastModIgnored { arg command, why;
      var line = "strata: % ignored: %".format(command, why), post = areaState[\modulation][\postIgnored];
      if (post.notNil) { post.value(line) } { line.postln };
  }
  fastModIndicesValid { arg command, indices;
      var bad = indices.detect({ arg index;
          (index[1].isInteger and: { index[1] >= 0 } and: { index[1] <= index[2] }).not });
      if (bad.isNil) { ^true };
      this.postFastModIgnored(command, "% % is not a whole number from 0 to %".format(bad[0], bad[1], bad[2]));
      ^false
  }
  fastModValuesFinite { arg command, values;
      var bad = values.detect({ arg value; value[1].isNaN or: { value[1].abs == inf } });
      if (bad.isNil) { ^true };
      this.postFastModIgnored(command, "% % is not a finite number".format(bad[0], bad[1]));
      ^false
  }
  receiveFastMod { arg command, values;
      areaState[\modulation][\received][command] = values;
  }
  ```
  `fastModIndicesValid`'s `index[1].isInteger` means an `"i"` argument that arrives as a Float fails; the engine checks pass integers.
- `zeroFastModChannels { arg first, count; context.server.sendMsg('/c_fill', first, count, 0); }` (:170-172).
- `fastModChannel { arg voice, noteSlot, destination; ^this.fastModChannelFor(voice, noteSlot, destination, this.fastModNoteSlots) }` (:156-158).
- The commands (:555-617), e.g. `setFastLfo`: indices `[[\lfo, lfo, lastLfo], [\voice, voice, lastVoice], [\destination, destination, lastDestination], [\shape, shape, lastShape]]`, then finiteness, then `rate = msg[5].clip(0.003, 50); depth = msg[6].clip(0, 1); offset = msg[7].clip(-2, 2);`, `receiveFastMod`, then `this.setFastLfo(...)` (called directly: `setFastLfo`'s body reaches `onFree` only through `areaCall`, so no chain; `setScatter` goes through `areaCall`, :601).
- Hold time for a hit: `seqGate` and `gateSeconds` are kept in `grainControls[voice]` by `setStageParam` (`StrataMix.sc:58-62`: `grainControls[voice][param] = value; this.setSynth(this.voiceMixKey(voice), param, value); ^true`); the stage's defaults are `seqGate 0`, `gateSeconds 0.1` (`voiceMixMod`, `StrataModulation.sc:223`), so `grainControls[voice][\seqGate]` is nil until Lua sends one.

### Modulation check names for the node-count and zeroing rules (`test/engine_check/modulation.scd`)

"modulation: one offset node at the head of fastModGroup from start to stop" (:349); "modulation: no command makes a node outside fastModGroup" (:413); "modulation: each command records its arguments, the continuous ones clipped" (:416); "modulation: out-of-range indices and non-finite values are ignored, one line each, and change no channel" (:452); "modulation: every fast-modulation channel reads 0" (:462); "modulation: fastModGroup sits before voiceGroup, at the head of xg, with the offset node alone once LFOs and scatter end" (:466); "modulation: one node per LFO through starts, shape changes, moves and stops at 20 Hz for 2 s, and none once stopped" (:567); "modulation: an LFO stopped, then re-gated with its shape after its node ended on the server ... comes back on exactly one new node" (:629); "modulation: two LFOs on one channel add" (:645); "modulation: a stopped LFO's channel returns to 0 while another on it keeps writing" (:654); "modulation: an LFO moved to another destination zeroes its old channel" (:665); "modulation: syncFastLfo sets the phase ..., and without a node makes none" (:738); "modulation: no failure while LFO and scatter nodes release" (:968); "modulation: the area leaves every voice on its synth source and every channel at 0" (:1722).

### The memory check's modulation lists (`test/engine_check/memory.scd:214-237`)

```
var modulationLimitsKB = (lfo: 9, strataScatter: 45, strataFastOffsets: 13.5);
var checkModulationSizes = {
    var group = Group.after(engine.processGroup), controlBus = Bus.control(server, 40);
    var shapes = [\Sine, \Tri, \Square, \Up, \Down, \Sah, \Smooth, \Drunk];
    var defNames = shapes.collect({ arg name; ("strataFastLfo" ++ name).asSymbol }) ++ [\strataScatter, \strataFastOffsets];
    var limitOf = { arg name; modulationLimitsKB[name] ? modulationLimitsKB[\lfo] };
    ...
    var sizes = if (missing.notEmpty) { [] } {
        defNames.collect({ arg name;
            sizeOf.({ arg index;
                Synth(name, [\out, controlBus.index + (if (name == \strataFastOffsets or: { name == \strataScatter }) { 0 } { index }),
                    \rate, 10, \depth, 0.5], group)
            })
        })
    };
```
A def not in `modulationLimitsKB` gets the LFO's 9 KB limit (`limitOf`). The memory check runs before every worst case (`checkModulationSizes.value`, :771).

---

## 5. The delay (1d, engine half) (`lib/engine/StrataEffects.sc`)

- `\strataDelay` (:152-157) quoted in E §3.
- `setDelay` (:268-274):
  ```
  this.addCommand(\setDelay, "fff", { arg msg;
      this.keepEffectControls(\delay, (time: msg[1], feedback: msg[2], mix: msg[3]));
      context.server.makeBundle(nil, {
          this.setSynth(\delay, \time, msg[1], \feedback, msg[2], \mix, msg[3] * this.effectLive(\delay));
          this.broadcastFxMix;
      });
  });
  ```
  The stub's `fx_commands` reads `this.setSynth(\delay, ..., \<control>, msg[i], ...)` pairs (`norns_stubs.lua:472-483`: pattern `\\([%w_]+)%s*,%s*msg%[(%d+)%]`; the `setSynth` call must end `);` on one statement), finds `\delay`'s def from `synths[\delay] = Synth(\strataDelay` (:465-468; `startDelay` :356), and takes each control's literal clip as the argument's limit.
- `keepEffectControls { arg key, controls; areaState[\effects][\controls][key].putAll(controls); }` (:284-286).
- `effectDefaults` (:377-381):
  ```
  effectDefaults { arg defName, names;
      var controls = SynthDescLib.global.at(defName).controls, defaults = ();
      names.do({ arg name; defaults[name] = controls.detect({ arg each; each.name == name }).defaultValue });
      ^defaults
  }
  ```
  Used at `startEffectsChain` (:387): `state[\controls][\delay] = this.effectDefaults(\strataDelay, [\time, \feedback, \mix]);`.
- `startDelay` (:354-359):
  ```
  startDelay { arg target, addAction, mix, fadeIn = 0;
      var controls = areaState[\effects][\controls][\delay];
      synths[\delay] = Synth(\strataDelay, [\in, this.mixBus(\delaySendPost), \out, delayBus,
          \time, controls[\time], \feedback, controls[\feedback], \mix, mix ? controls[\mix],
          \fadeIn, fadeIn], target, addAction);
  }
  ```
- `setEffectBypass` (:316-349): whole in the file; the lift re-creates with `this.startDelay(synths[\filterReverb], \addAfter, 0, 1)` (:342), then `this.setSynth(key, \mix, this.liveMix(key)); this.broadcastFxMix;` in one bundle; the bypass frees after `bypassFadeTime` on `SystemClock` (:330-336).

### Effects checks that compare with 3.0 or read the delay's defaults (`test/engine_check/effects.scd`)

- `\strataCheck30Delay` (:97-104, its own literal `2` and clips) and `checkChain30 = { arg label, fx, sweep; ... }` (:487-532): sends `command.(\setDelay, *fx.copyRange(4, 6))` (:493) and, swept, `command.(\setDelay, fx[4], fx[5], sweep.(elapsed))` (:519); check "effects: with every send at 1 the output matches 3.0's chain within -60 dB" (:527-529). Called at :998 ("defaults", `[5000.0, 0.5, 0, 0.0, 0.375, 0.4, 0.0, 0.3, 0.8, 0.5]`) and :999 ("filter on, delay mix swept by an LFO").
- `checkFreshDefaults` (:364-389): reads a fresh engine's `\delay` node `[\time, \feedback, \mix]` (:372) and checks "effects: a fresh engine's delay starts at 0.375 s, feedback 0.4 and dry, ..." (:382-385), called at :996.
- Others reading the delay: "effects: a bypassed delay returns its 1 MB to the pool" (`freedKB > 900`, :775-788); "setDelay sets time / feedback / mix" (:1021-1025); "effects: setDelay and setReverb broadcast their mixes on fxMix (0 and 0.3)" (:1009-1012); "setDelay during the bypass fade ..." (:843-857); `checkEffectSendsReported` (:457-473, a three-argument `setDelay`).
- Every three-argument `setDelay` in the checks: effects.scd 18 lines (listed in §0 item 2), mix.scd 3 (:590, :624, :676), record.scd 2 (:309, :326, `h.command`), and structure.scd :283 (the `"fff"` signature check).

### Lua tests on the FX defaults and limits (`test/unit/docs_test.lua`)

- `"the FX SynthDefs' defaults equal the Lua param defaults (#25)"` (:453-485): sends every param of the `strata_fx` group through `send_param_to_engine`, then for each `fx_commands` setting compares the last call's argument with `engine_spec.synthdef_defaults[def][control]` (`assert_near ... 1e-6`) and requires **every** argument of the command to set a control (:481-483: `set_arguments[index]` for `1..#signatures[name]`). So a fourth `setDelay` argument must be sent as `\pingPong, msg[4]` in that `setSynth`, `pingPong` needs a numeric default in the arg list, and the Lua param that feeds it must be in the `strata_fx` group.
- `"the engine stub rejects a NaN or infinite argument (#477)"` (:680): `assert_engine_rejects("finite", "setDelay", nan, nan, nan)`.
- `"the engine stub range-checks continuous arguments at the engine's own limits (#51)"` (:699-735): `check_limits("setDelay", {0.375, 0.4, 0}, 1, "time", engine_limit("setDelay", 1, "time"))` and the same for feedback and mix (:723-725); `patched_limits.setDelay[2].high` from a patched `feedback.clip(0, 0.95)` (:729-734).
- Other Lua tests reading `setDelay` calls by argument index: `lfos_test.lua:988-1022` (args 2-3), `gestures_test.lua:449`, `params_setup_test.lua:255-261`, `voice_mix_test.lua:212`.
- The one Lua sender: `send_delay_to_engine` (`lib/engine_sync.lua:467-470`): `engine.setDelay(engine_param_value("delay_time"), engine_param_value("delay_feedback"), engine_param_value("delay_mix"))`.

---

## 6. Lua's view of commands

### `engine_argument_checks` (`test/norns_stubs.lua:606-732`)

Three entries of different shapes (:660-727):
```
voiceOn = voice, voiceOff = voice, retrigger = voice, setModSpeed = voice,
...
setMasterDrift = none, setReverb = none, setDelay = none,
...
noteOn = note_slot, noteExpression = note_slot,
noteOff = function(args) return note_slot(args) or range("cut", args[3], 0, 1) end,
setNotePool = function(args) return range("size", args[1], 0, spec.note_pool_max) end,
```
with helpers `voice`, `slot`, `note_slot` (`voice(args) or range("slot", args[2], 0, spec.note_slots - 1)`, :649), `range`, `float_range`, `enumerated`. Every entry is wrapped so `continuous(command, args)` then checks `spec.argument_limits[command]` (:728-730). `stubs.install` asserts an entry exists for every engine command: `assert(argument_checks[command_name], "the engine stub has no argument check for engine." .. command_name)` (:3086-3088), so a new `addCommand` without an entry fails every test file.

### What the stub reads from the SC source (comments stripped first, `strip_sc_comments`)

- Signatures: `addCommand%(%s*\\(%w+)%s*,%s*"([^"]*)"` (`engine_signatures_from_source`, :212-218).
- Polls: `addPoll%(%s*\\(%w+)` or `addPoll%(%s*"name"` (:226-232).
- Numbers (`engine_number`, :297-301): `var <name = N;` or `name { ^N }`, **integers only** (`(%d+)`); the names read are fixed in `engine_spec_from_source` (:418-432: `numVoices`, `numBuffers`, `bufferSeconds`, `standardBufferSeconds`, `bufferStateStride`, `bufferStateLoads`, `numModSlots`, `numFastDestinations`, `fastModNoteSlots`, `numFastLfos`, `numFastLfoShapes`, `noteSlots`, `notePoolMax`); a new constant needs a line there and possibly in `engine_spec_problems` (:562-583).
- SynthDef controls and defaults: `SynthDef%(%s*\\([%w_]+)%s*,%s*{` then `arg ...;` or `|...|` (:448-461); a default is read only as a plain number (`=%s*(%-?[%d%.]+)%s*$`).
- Control limits in a def (`synthdef_control_limits`, :399-413): `name.clip(lo, hi)` or `name.lag(t).clip(lo, hi)` with literal numbers (`CLIP_LIMITS`, :386: `%.clip%(%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*%)`); a control clipped to two ranges is an error.
- Argument limits (:469-490): the FX controls a command sets (`fx_commands`, above) and the command's own `msg[i].clip(lo, hi)`, named by `name = msg[i].clip` (else "argument i").
- Enumerations: `name.round.clip(lo, hi)` with integer literals (:542-547); `envShape` from `envBuffers = [...].collect` (:548-552).
- `grain_params`: every control of the defs named in any `grainDefs: [...]` (:511-517), the keys of every `grainParamHandlers: (...)` Event (`event_keys`, :519-521), and `param == \name` in `setGrainParam`; minus `engine_controls` (`engineOwnedControls` and `modSlotControlNames` × slots, :529-536) and `voiceLevelGrainControls` (:537-540). So a handler-only param (`rootNote`) becomes sendable by its handler key alone; a named control (`\name.kr`) is not a grain param.
- `voice_synthdefs` from `voiceSynthDefs = [...]` (:492-498).

### `test/sync_check.lua`'s `PENDING_COMMANDS` (:210-218)

```
-- Commands the engine has before the script calls them, so the check lets
-- them go uncalled while their engine side lands first. Empty today (3.5's
-- four note commands left it when S.lib.notes began calling them). A
-- pending command a script file calls fails the check, as does
-- a name the engine does not have, so the list never outlives its use. One
-- name per line: a release whose engine lands a command before its caller
-- adds it here, and the caller's change removes it.
sync_check.PENDING_COMMANDS = {
}
```
Rules (`check_sources`, :224-270): a pending name the engine lacks fails (:230-235); a pending name a Lua file calls fails (:253-256); any other command no Lua file calls fails ("engine command \\X is never called from the script's Lua files", :266-267). The Lua suite runs the same check (`docs_test.lua:15`), and CI runs `lua5.3 test/sync_check.lua`. A command whose signature changes (`setDelay`) must change its Lua caller in the same commit (argument count, :245-251).

### The AGENTS.md command-table test (`docs_test.lua:790-811`)

```
local name, args, signature = line:match('^| `engine%.(%w+)%((.-)%)` | `"(%a*)"` |')
```
Every engine command needs exactly one row with the same signature and an argument list whose comma count + 1 equals `#signature`; every row must name an engine command; and no maintained doc may mention `engine.<name>(` of a command the engine lacks (:812-827). So each new command's row lands in `AGENTS.md` in the same commit as its `addCommand`.

---

## 7. Running the checks

- This machine: `/usr/bin/sclang` and `/usr/bin/scsynth` are SuperCollider **3.14.1** (`supercollider-language 1:3.14.1+repack2-1build1`); `jackd`, `docker` present; norns at `~/src/norns`.
- JACK first (`docs/checks.md`, On Linux): `jack_lsp` fails when no server runs; then
  `nohup jackd --no-realtime -d dummy -r 48000 -p 1024 >/tmp/jackd.log 2>&1 &`
- One area on 3.14.1 (a port of its own per worktree; avoid 57120 and the few above it; two runs on one port collide; `flock /tmp/strata-engine-check.lock ...` serializes runs on a shared port):
  `STRATA_SC_PORT=57141 STRATA_ENGINE_CHECK_AREAS=positions SCLANG=/usr/bin/sclang QT_QPA_PLATFORM=offscreen test/run_engine_check.sh ~/src/norns`
  (comma- or space-separated names run in one sclang; a name with no file fails at once).
- All areas on 3.14.1: the same without `STRATA_ENGINE_CHECK_AREAS`; it runs CI's shards one after another, each in its own sclang, read from the workflow through `test/run_engine_check_313.sh -l`; about 20 minutes (1202 s at 3.5.0; areas sum 1165 s). `ENGINE_CHECK_TIMEOUT` (1800 s default) applies to each sclang. `STRATA_ENGINE_CHECK_ONE_SCLANG=1` runs every area in one sclang.
- On 3.13 in Docker: one area `STRATA_ENGINE_CHECK_AREAS=positions test/run_engine_check_313.sh ~/src/norns`; a full run `test/run_engine_check_313.sh -j 3 ~/src/norns` (CI's shards, one container each, `-j` at once; each container has its own network, so no port choice is needed); `-n` repeats, `-o` keeps logs, `-l` lists shards, `-c` reclassifies. The image `strata-sc313` builds on first use in about a minute. Each container is capped at `STRATA_SC313_MEMORY` (8g).
- Per-area times (3.13, 3.5.0, workflow comment): lifecycle 114, record 113, buffers 100, memory 95, modulation 89, effects 87, notes 79, voices 75, rings 69, mix 69, freeze 63, loops 54, variation 52, grains 38, files 29, waveform 23, positions 8, structure 4, performance 3 (s).
- A run fails on any `ERROR`, `WARNING`, `FAILURE`, `alloc failed`, `Too many grains` or `Strata invariant broken` line (`docs/checks.md:30`); an `strata: <command> ignored:` line posted outside the check's `postIgnored` hook is plain output.
- Lua: `lua test/run.lua [filter]`, `luajit test/run.lua`, `lua test/sync_check.lua`.

## Not found

- Whether a three-argument `command.(\setDelay, ...)` against an `"ffff"` handler errors or silently sends `\pingPong, nil` (the helper does not check arity; what `setSynth` and `putAll` do with a nil value was not run).
- Any engine check that enumerates area Event keys.
- Any structure test that bounds `List` growth (the rule is in the notes only).
- A measured cost for any 3.7 UGen (all figures in E §7 are estimates).

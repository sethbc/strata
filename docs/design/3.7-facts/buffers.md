# 3.7 design facts: buffers

Area: loading, recorded takes, transients, what a slot stores, the BUFFER page, the grids' position pages, normalize. Read-only survey of `main` at 334429aa (2026-11-15). Every fact cites file:line. "Code wins" marks a place where the notes and the code disagree; "not found" marks what could not be established. No design is proposed; the constraints a design must meet are stated as facts.

SuperCollider facts are from `~/src/supercollider` at tag `Version-3.13.0` (norns ships 3.13.0), read with `git show Version-3.13.0:<path>` (no checkout).

---

## 1. Loading a file

### The flow, command to report

1. `loadBuffer` (`"isf"`) is added at `lib/engine/StrataBuffers.sc:67-69` and calls `this.areaCall(\loadSlot, msg[1], msg[2].asString, msg[3])`.
2. `loadSlot` (`lib/engine/StrataBuffers.sc:235-274`):
   - checks the slot, counts the load (`bufferLoads[index] + 1`, :238-239);
   - opens the file in sclang with `SoundFile.openRead(path.standardizePath)` (:240); a nil file is `rejectLoad` (:241);
   - `slotFrames = [(sampleRate * bufferSeconds).floor.asInteger, buffersL[index].numFrames].minItem` (:243), where `sampleRate` is the file's;
   - `startFrame = start.asFloat.max(0) * sampleRate`, then a start at or past the end becomes `(file.numFrames - slotFrames).max(0)` (:247-248); `frames = (file.numFrames - startFrame).min(slotFrames)` (:249);
   - an empty file (`frames < 1`) is rejected (:252); `file.seek(startFrame, 0)` (:253); `peaks = FloatArray.newClear(this.waveformPoints)` (:254);
   - up to `loadCheckAtOnceFrames` (`(this.standardBufferSeconds * context.server.sampleRate).floor.asInteger`, :279; 768000 frames at 48 kHz) it decodes inline, inside the command: `fileDecodes(file, frames, false, peaks)` (:255-260), then `applyLoad` or `rejectLoad`;
   - a longer file (high tier only) first cancels a recording (:262-263), then `fork({ ... }, SystemClock)` runs `fileDecodes(file, frames, true, peaks, { load > this.loadsSuperseded(index) })` (:265-273), and applies only while `load > this.loadsSuperseded(index)`.
3. `applyLoad` (`lib/engine/StrataBuffers.sc:299-347`): `stopRecording`, `slotChanged(index, load)`, `bufferFrames[index] = 0`, the rate set to the server's, `bufferChanged` (a 0 s report) (:301-308); then `afterSlotFade` (60 ms when a grain synth reads the slot, at once otherwise: :382-388) zeroes both buffers and has **the server read the file itself** with `readChannel(path, startFrame, frames, 0, false, [0])` and `[rightChannel]` (:322-323); a `fork` waits on `context.server.sync` (:325), then on success `bufferSampleRates[index] = sampleRate`, `storeSlotPeaks(index, peaks)` and `writeSlotPeaks(index, frames, { bufferFrames[index] = frames; this.bufferChanged(index) })` (:336-342). The length report therefore follows the peaks file's rename.
4. `bufferChanged` (`lib/engine/StrataBuffers.sc:191-203`) sends the slot's new length to the live grain synths and `bufferStatePoll.update(this.bufferStateReport(index, seconds))` (:202), and stores the announced seconds the periodic poll repeats (:201).

**Where samples pass through sclang during a load: only in `fileDecodes`** (the check). The audio that plays is read by scsynth's `/b_readChannel` (`StrataBuffers.sc:322-323`); sclang never holds it.

### `fileDecodes` (`lib/engine/StrataFiles.sc:100-122`)

```
while { done < frames } {
    binEnd = this.peakBinEnd(bin, frames);
    while { binEnd <= done } { bin = bin + 1; binEnd = this.peakBinEnd(bin, frames) };
    wanted = loadCheckFrames.min(binEnd - done);
    chunk = this.freshReadArray(wanted * channels);
    file.readData(chunk);  // shrinks chunk to the samples decoded
    ...
    if (decoded > 0) { peaks[bin] = peaks[bin].max(chunk.peak.min(1.0)) };
    ...
    if ((decoded < wanted) and: { done < frames }) { ^(frames - done) <= loadShortfallFrames };
    if (yielding and: { done < frames }) { this.yieldToCommands(0); if (keepGoing.notNil and: { keepGoing.value.not }) { ^false } };
};
```

- Chunk size: `loadCheckFrames = 16384` frames (`lib/Engine_Strata.sc:60`), interleaved, so `16384 * channels` samples per read; every read is cut at the next 64-bin boundary (`peakBinEnd`: `((bin + 1) * frames) div: this.waveformPoints`, `StrataFiles.sc:126-128`), so no chunk spans two bins. Notes: "at most 64 more reads than the check alone" (`docs/notes/engine/waveform.md`, Owns, last paragraph).
- Each read goes into a fresh `Signal` (`freshReadArray`: `^Signal.newClear(size)`, `StrataFiles.sc:139-141`).
- A routine yields after every chunk through `yieldToCommands(0)` (`StrataFiles.sc:176-178`: `wait.max((Main.elapsedTime - thisThread.seconds) + this.commandGap).wait`, `commandGap` 0.2 ms, :183). A short file (inline path) never yields: the whole decode runs inside the command.
- What is computed: (a) the decode-length check, rejecting a file that decodes more than `loadShortfallFrames` (4096, `lib/Engine_Strata.sc:61`) short; (b) the 64 peaks, `chunk.peak.min(1.0)` per bin, the largest absolute sample of the bin across both channels (interleaved), clipped to 1. Also a counter `areaState[\files][\decodeChunks]` for the check (:111).
- **Not found: a check for bad sample values (NaN, inf) at load.** Nothing in `StrataFiles.sc`, `StrataBuffers.sc` or `StrataWaveform.sc` tests samples; the only `isNaN` in the record or buffer areas is `recordSendKnown` (`StrataRecord.sc:337`). Bad values are zeroed only on the server, in the nodes AGENTS.md lists (`zeroBadValues` in the filters, `\strataMod`, ring writers, the mix stage).

### Measured times (all from the notes; none on a Pi)

- 16 s of 48 kHz stereo: the decode check "about 2 ms for a WAV and 9 ms for a FLAC on a desktop" (`StrataFiles.sc:80-82`, `docs/notes/engine/buffers.md`, Damaged files).
- 60 s WAV check: "a few tens of ms"; a 300 s WAV loads (check and read) in "about 0.4-0.65 s" on a desktop (`docs/notes/engine/buffers.md`, Long files; `docs/notes/engine/files.md`, Long saves).
- The 300 s peak scan: 880 chunks of 16384 stereo frames, `peak` 13-23 ms of sclang, against 3.6-3.9 s for `maxItem` (3.13 and 3.14.1) (`docs/notes/engine/waveform.md`, Must not break, "The peak scan allocates nothing per sample").
- A 300 s FLAC "takes seconds on a Pi" (comment, `StrataFiles.sc:89`): **not measured**. Pi 4 times for long saves are on the hardware list (`docs/notes/engine/files.md`, Long saves). **Not found: any Pi measurement of a load or the peak scan.**

### The rules that bound sclang work (#131 and its family)

- **Every `readData` reads into a fresh array** (`freshReadArray`); reuse makes 3.13's collector abort later (`docs/notes/engine/files.md`, Must not break, first item; `StrataFiles.sc:130-138`). Structure test: `test/unit/structure_test.lua:1174-1199` (`stale_reads`: each `.readData(x)` must have `x = this.freshReadArray(` on the line before or in the same statement).
- **No sclang function per sample or frame** in the sample paths (`docs/notes/engine/files.md`, Must not break, second item; "sclang's garbage collector under heavy allocation"): no `do`, `collect`, `fill` or a call per sample. Structure test `per_sample_loops` (`structure_test.lua:1220-1227`) flags `{ arg `, `{ |`, `.do(`, `.do {`, `.collect(`, `.collect {`, `.fill(`, `.select(`, `.reject(`, `.every(`, `.any(`, `.inject(`, `.sum(`; applied to `interleaveChunk`, `interleaveKeys`, `fileDecodes`, `freshReadArray` and `interleaveFiles`' chunk loop (`structure_test.lua:1965-1988`).
- **The peak scan allocates nothing per sample**: only the fresh chunk arrays and one 64-value `FloatArray` per load; "No `abs`, `copyRange`, `collect` or per-bin array either" (`docs/notes/engine/waveform.md`, Must not break). Structure test `peak_scan_findings` (`structure_test.lua:3083-3125`) bans the text `.abs`, `abs(`, `copyRange`, `collect`, `maxItem`, `minItem`, `FloatArray.fill(n, {` and stale reads in `fileDecodes` and every method of `StrataFiles.sc` it calls (`peakBinEnd`, `freshReadArray`, `yieldToCommands`, ...). Note: the ban on `.abs` and `copyRange` is textual: `Signal.abs` and `copyRange` are C primitives in 3.13 (below), but the test refuses them in the scan.
- **No List or Array that grows without bound** in code that runs while a long save or load allocates (an OSC responder, a polling loop, a chunk loop): a List passing 128 entries inside a responder during a save corrupted 3.13's collector (`docs/notes/engine/files.md`, Must not break; AGENTS.md). Make it `List.new(n)` or bound it.
- **Chunk loops wait through `yieldToCommands`, never a plain `wait`** (`docs/notes/engine/files.md`, Must not break, last item).
- **Long-lived frames** (#211): a method that keeps a closure and is called from a function goes through `areaCall` (AGENTS.md; `structure_test.lua`'s `AREA_CALL_METHODS`, which lists `loadSlot`, `clearSlot`, `saveSlot`, `recordSlot`, ...).
- CI runs the engine check in shards, each in its own sclang, so no sclang's allocation adds up (`docs/notes/engine/files.md`, #131 section, CI).

**Primitives the code relies on today** (named in `docs/notes/engine/files.md` and `waveform.md`): `Signal.peak` (`_SignalPeak`), `Signal.clip` (`_ClipSignal`), Signal arithmetic, `at` with an index Array (returns an Array of Floats), `putEach` with Array keys and values (`_ArrayPutEach`; never a FloatArray or Signal there, which it misreads), `copySeries`, the `(a, b .. c)` series, `extend` (`_ArrayExtend`, `interleaveChunk`'s padding, `StrataFiles.sc:162`). `FloatArray.newClear`, `Signal.newClear`.

**Other 3.13 primitives on `Signal`** (`SCClassLibrary/Common/Math/Signal.sc` at `Version-3.13.0`): `abs` (`_Abs`, :227), `squared` (`_Squared`, :229), `sqrt` (:231), `integral` (`_SignalIntegral`, :117, a running sum), `rotate` (`_SignalRotate`, :107-109), `reverse`, `normalize` (`_SignalNormalize`, :86-88), `fft` and `ifft` (`_Signal_FFT`, `_Signal_IFFT`, :213-223; size a power of two, a cosine table from `fftCosTable`), `+ - * /`, `min`, `max`, `absdif`, `thresh` with a Signal or a number (`_Add` ... `_Thresh`, :264-290; falling back to `performBinaryOpOnSignal`), `clip`, `wrap`, `fold` (:295-297), `hanWindow`, `welWindow` (:257-260). On `ArrayedCollection` (`SCClassLibrary/Common/Collections/ArrayedCollection.sc`): `copyRange` (`_ObjectCopyRange`, :137-142), `copySeries` (`_ObjectCopySeries`, :143-150, returns the receiver's class, so a Signal stays a Signal), `indexOfGreaterThan` (`_ArrayIndexOfGreaterThan`, :77-79), `indexOf` (:74), `putEach` (:171-173). **Not primitives**: `sum`, `maxItem`, `minItem`, `mean` (Collection methods, a function per element); binary operations between two **Arrays** (`SequenceableCollection.performBinaryOpOnSeqColl`, a `size.do` per element, `SequenceableCollection.sc:1097-1106`); `newFrom` (`Collection.sc:2-6`, a `do` per element).

### What a finer envelope would cost, by the notes' reasoning (estimates, not measured)

The notes justify 64 bins by: bin-aligned reads add at most 64 reads; one 64-value `FloatArray` per load; the per-bin peak is one primitive call. By the same reasoning for N bins:

| slot | frames at 48 kHz | reads today (64 bins) | frames per bin at N = 2048 / 4096 | reads at N = 2048 / 4096 |
|---|---|---|---|---|
| 16 s | 768000 | about 47 + 64 = 111 at most | 375 / 187 | 2048 / 4096 (each bin is shorter than a chunk, so one read per bin) |
| 300 s | 14.4 M | about 879 + 64 = 943 at most | 7031 / 3515 | 2048 / 4096 |

- The bytes decoded are the same; the number of `readData` calls and fresh Signals rises to N, each smaller (a 16 s slot at 4096 bins: 187 stereo frames, 1.5 KB). The collector's scan credit is `1 << sizeclass` per allocation (`docs/notes/engine/files.md`, #131 section), so total credit tracks bytes allocated, not the count; per-call overhead of `readData` on a Pi is **not measured**.
- A short file decodes inside the command, with no yield (`StrataBuffers.sc:255-260`): N reads in one command hold matron's commands for all of them.
- An RMS bin can be had with primitives per chunk: `chunk.squared` then `.integral` (each allocates a Signal the chunk's size) and its last value; `sum` is not a primitive and the structure test flags `.sum(`.
- Downstream of the scan, today's per-bin code runs a sclang function per bin, fine at 64 and N-fold at N: `peaksContent` (`StrataWaveform.sc:282-285`, `collect` + `peakText` per value + `join`, run at every write and, during a playable recording, in `peaksUnchanged` every 0.5 s), `spreadPeaks` (:331-341) and `shrunkPeaks` (:366-376) (nested `do` per bin). `storeSlotPeaks` sends one `b_setn` of all values (`StrataWaveform.sc:48-51`); 3.13's `Buffer.setnMsgArgs` builds a `List.new` that grows to N + 2 entries (`SCClassLibrary/Common/Control/Buffer.sc:409-424`), the kind of growth the List rule warns about past 128 entries. `readSlotPeaks` is one `b_getn` of all values (`StrataWaveform.sc:315-327`; `Buffer.getn`, `Buffer.sc:449-466`, one message): 4096 floats is 16 KB in one reply. **Not verified**: the reply size limit on norns' sclang-scsynth link.
- The peaks file would hold N values at three decimals (`peakText`, `StrataWaveform.sc:54-57`): about 6 bytes each, 24.6 KB at 4096, rewritten at most every 2 s during a playable recording (#523's card-write budget), parsed by Lua one `tonumber` per token (`lib/waveforms.lua:65-69`).
- The record synth's peak bins (section 2) are written once per control block: a bin narrower than a block (64 frames on norns, `docs/notes/engine/rings.md`) is skipped. At N = 4096 a take shorter than 4096 x 64 frames (5.5 s at 48 kHz) leaves bins unwritten.
- The server peak buffers are server memory, outside the 8 MB real-time pool (as the FFT buffers are: `docs/notes/engine/freeze.md`, Must not break, Real-time memory): 8 x N x 4 bytes, 128 KB at 4096.

### Is an onset pass possible with primitives only?

Facts that decide it (no measurement exists):
- **Energy difference**: per chunk, `chunk.squared.integral` (two primitive Signals) then `copySeries(first, second, last)` (primitive, keeps the Signal class) at hop ends gives the cumulative energy at each hop; `rotate`, `-`, `max(0)` (Signal with Signal or number, primitives) give the per-hop rise; `indexOfGreaterThan` (primitive) finds the first hop above a threshold. Interleaved stereo needs stride-2 series. One sclang step per onset found, none per sample. Every step allocates a Signal of the chunk's or the hop count's size.
- **Spectral flux**: `Signal.fft(imag, cosTable)` is a primitive; magnitude via `squared`, `+`, `sqrt` (primitives); flux via `-`, `max(0)` and a sum (`integral` and its last value). One `fft` call and several Signal allocations per analysis frame, with overlapping frames needing either a re-read or `copyRange`/`copySeries` of a chunk (the peak-scan test bans `copyRange` by name in `fileDecodes` and its callees). A 300 s file at a 512-frame hop is about 28 000 frames.
- Neither runs a function per sample, which is what #131's rule forbids; both add per-chunk and per-frame allocations the peak scan does not make, and both would sit inside `fileDecodes`, which the two structure tests scan.

---

## 2. Recorded takes

### How a take's audio reaches the slot

- `\strataRecord` (`lib/engine/StrataRecord.sc:96-138`) writes the slot's buffer pair on the server: `BufWr.ar((old * keep) + fresh[channel], bufnum, phase, 1)` (:128-131), `phase = Phasor.ar(0, armed, 0, frames)` (:106). Armed at once or when `Amplitude.kr(loudest, 0.001, 0.05)` passes `threshold` (:102); with a threshold a fixed 10 ms `DelayN` pre-roll (:103). The take's samples never pass through sclang while it records.
- One record synth per slot, in the tap group after the master (`docs/notes/engine/record.md`, Must not break). Memory: a record synth takes at most **24 KB** of the pool; with every slot recording the mixed worst case still leaves at least 3 MB on both tiers (`docs/notes/engine/memory.md`, items 7 and 9).
- Replace or playable: `recordSlot` (`StrataRecord.sc:395-445`); playable when `(feedback > 0) or: { loop > 0 }` (:415) and the slot is empty or at the server rate.

### How its 64 peaks are made

- In the record synth (`StrataRecord.sc:116-127`):
  ```
  var bin = (head * points / peakFrames).floor;
  var entering = BinaryOpUGen('!=', bin, Delay1.kr(bin)) + Impulse.kr(0);
  var stored = BufRd.kr(1, peakBuf, bin, 1, 1);
  var oldPeak = Latch.kr(stored, entering);
  var peak = Peak.kr(fresh[0], entering).max(Peak.kr(fresh[1], entering));
  BufWr.kr(Select.kr(armed, [stored, ((oldPeak * feedback) + peak).min(1)]), peakBuf, bin, 1);
  ```
  So a bin holds `min(1, old peak x feedback + the largest |sample| written since the head entered it)`, of the signal after the record level and the record envelope (`fresh = sig * rec`, :115). `peakFrames` is the take's record length D (`sendTake`'s `length`, :492-504). Written once per control block (k-rate).
- The peak buffer is one 64-frame mono server buffer per slot (`StrataWaveform.sc:25`).
- sclang reads it with one `b_getn` (`readSlotPeaks`, `StrataWaveform.sc:315-327`): at the take's end (`endTake`, `StrataRecord.sc:635-658`; a replace take stopped at F frames uses `ceil(64 x F / D)` bins spread over 64, :638) and, for a playable recording, every `peakRefreshSeconds` (0.5 s, :43) in `refreshRecordPeaks` (:560-580), which writes the peaks file only when the overview changed (`peaksUnchanged`) and at most every `peakWriteSeconds` (2 s, :47). Lua rereads a playable recording's file every `WAVEFORMS.refresh_seconds` (2 s, `lib/constants.lua:38`; `lib/waveforms.lua:167-181`).
- A playable recording that extends its slot first puts the old overview on the new length (`shrinkSlotPeaks`, `StrataWaveform.sc:351-358`, `shrunkPeaks` :366-376) (#313).

### How the scratch file is written

`endTake` calls `writeSlot(index, scratchPath(index), done)` after `ended` (`StrataRecord.sc:651-653`). `writeSlot` (`StrataFiles.sc:268-373`): the **server** writes each mono buffer's valid frames to a temporary float WAV (`buffersL[index].write(tempPaths[0], "wav", "float", frames, firstFrame)`, :292-293, i.e. `/b_write`); then **sclang** interleaves them in 8192-frame chunks (`interleaveFiles`, :391-437: `left = this.freshReadArray(chunkFrames); sources[0].readData(left)`, :416-418, `interleaveChunk`, `writeData`, `yieldToCommands(writeChunkWait)`) into a stereo int16 WAV `.part`, renamed into place by the mover. Path: `scratchDir +/+ ("buf" ++ (index + 1) ++ ".wav")` (`StrataFiles.sc:185-187`), `~/dust/audio/strata/scratch/buf<n>.wav`.

**So a take's samples do pass through sclang, once, in the scratch write's interleave**: 8192-frame mono chunks of each channel, in a routine that yields between chunks, after the take has ended and its length and `ended` have been reported. The same interleave runs for every `saveBuffer`. A save abandoned for a newer write to the path stops early (`keepGoing`), so the interleave does not always see every chunk.

### Options to find transients in a take (facts only)

- **The load path's scan does not run on a take in the session that recorded it**: `fileDecodes` runs only in `loadSlot`. At the next start the restore loads the scratch path through `load_buffer` (`lib/buffers.lua:1007`), so `loadSlot` and `fileDecodes` then scan it like any file. A load is never analysis-only: `applyLoad` always zeroes the slot after the fade and re-reads it (`StrataBuffers.sc:303-323`), which silences the voices reading it for the fade.
- **The scratch write's interleave** is the one place the take's samples pass through sclang in the session (above); it runs after the length report.
- **Server-side UGens in norns' 3.13 core** (no sc3-plugins; CI compiles without them, `ROADMAP.md:49`; norns itself ships sc3-plugins 3.13.0, `docs/design/3.2-design.md:70`):
  - `Onsets` exists in core: `SCClassLibrary/Common/Audio/MachineListening.sc:30-42` (`*kr { |chain, threshold=0.5, odftype=\rcomplex, relaxtime=1, floor=0.1, mingap=10, medianspan=11, whtype=1, rawodf=0|`), built in `ML_UGens` (`server/plugins/CMakeLists.txt:127-131`, `Onsets.cpp`, `onsetsds.c`). It takes an FFT chain; its help recommends 512 or 1024 frames at 44.1 kHz and 50% hop (`HelpSource/Classes/Onsets.schelp:50`), and its examples use `FFT(LocalBuf(512), sig)` (:84).
  - Also in core: `Amplitude` (used today), `Slope` (`Filter.sc:217`), `Peak`, `RunningMax`, `PeakFollower`, `Trig`, `SendReply`, `Timer`, `Sweep` (`Trig.sc`), `FFT`/`PV_*` (`FFT_UGens`), `SpecFlatness`, `SpecCentroid`, `Loudness` (`MachineListening.sc`).
  - `Coyote` is **not** in 3.13 core (no file in the tag's tree); it is sc3-plugins' (BhobUGens).
- **No `LocalBuf` in any engine SynthDef** (`docs/notes/engine/freeze.md`, Must not break, first item; structure test `structure_test.lua:1157-1170`). The spectral freeze's FFT buffers are server buffers allocated in sclang: `state[\spectralBuffers] = if (tier == \high) { Array.fill(numVoices, { Array.fill(2, { Buffer.alloc(context.server, this.spectralFrames, 1) }) }) } { [] }` (`lib/engine/StrataFreeze.sc:73-76`, `spectralFrames` 2048, :19), passed to the def as `fftL`/`fftR` (`StrataFreeze.sc:117`). The standard tier allocates none. A spectral writer takes about 80 KB of the pool for two 2048-frame chains (`freeze.md`, Real-time memory); the FFT buffers themselves are outside the pool.
- A node added to the record synth or beside it changes the measured budget: AGENTS.md "A new delay line, table or node per voice needs the budget re-measured"; the record synth's 24 KB is a checked limit (`memory.md` item 9).
- A server-side reply per onset would arrive through an `OSCFunc`; the List rule (above) bounds what such a responder may accumulate.
- **Not found**: any existing onset, transient or slice code anywhere in `lib/` or `lib/engine/` (`grep -i onset|transient|slice` over the engine and Lua finds none).

### Overdubs and loop recordings

- The audio changes on every pass: `old x keep + new x rec` (`StrataRecord.sc:114, 130`).
- The bins then hold `min(1, oldPeak x feedback + new peak)` (:127): an upper bound that adds magnitudes, not the true peak of the mixed audio; it can saturate at 1 (`refreshRecordPeaks` then stops writing the file: `peaksUnchanged`).
- A loop recording's scratch write happens only once, at its stop (`endTake`); while it runs no sclang pass over its audio exists.
- Peaks refresh every 0.5 s in sclang, the file at most every 2 s, Lua at most every 2 s (above).

---

## 3. Engine to Lua data paths

### Polls

matron's `/poll/value` handler is typed `"if"` (one float) and its data-blob polls are broken, so a string or table cannot reach Lua (`docs/notes/engine/buffers.md`, Polls, first sentence). Five engine polls (`grep addPoll`): `bufferState` (`StrataBuffers.sc:88-94`), `bufferLoadFailed` (:104), `bufferSaveResult` (`StrataFiles.sc:39-41`), `recordState` and `takeWriteFailed` (`StrataRecord.sc:160, 166`).

| Poll | Value | Code |
|---|---|---|
| `bufferState` (periodic, one slot every 0.25 s, then the slot length; every change at once) | `((load * (numBuffers + 1)) + index) * 1000 + seconds`, `load` = `bufferLoads % 7`; index `numBuffers` with load 0 = the slot length | `StrataBuffers.sc:145-148`, `bufferLengthValue` :165 |
| `bufferLoadFailed` | `((load * 2) + emptied) * numBuffers + index` | `StrataBuffers.sc:173-175` |
| `bufferSaveResult` | `((save * 2) + failed) * numBuffers + index` | `StrataFiles.sc:60-62` |
| `recordState` | `((record * 4) + state) * numBuffers + index`, state 0 armed, 1 recording, 2 ended, 3 canceled | `StrataRecord.sc:217-219` |
| `takeWriteFailed` | `record * numBuffers + index` | `StrataRecord.sc:176` |

`bufferState`'s largest value is 61300, below 2^16, so a float32 keeps it to 2^-8 s (`StrataBuffers.sc:24-28`); seconds are rounded to 0.01 and at least 0.01 for any slot with frames (`bufferStateSeconds`, :126-130). The other four are exact for the first 2^20 commands of a slot. Encodings table: `docs/notes/engine/buffers.md`, The polls' encodings.

There is no poll with room for a position list: each message is one float, and `bufferState`'s float is already packed to below 2^16.

### The peaks file

- Path: `peaksPath(index)` = `this.allocSettingsDirectory +/+ ("buf" ++ (index + 1) ++ ".peaks")` (`StrataWaveform.sc:42-44`), i.e. `~/dust/data/strata/buf<n>.peaks`; Lua's `peaks_path(slot)` = `S.lib.scenes.scene_data_dir .. "buf" .. slot .. ".peaks"` (`lib/waveforms.lua:45-47`; `scene_data_dir = _path.data .. "strata/"`, `lib/scenes.lua:1019`).
- Format (`writePeaksFile`, `StrataWaveform.sc:297-306`; `peaksContent` :282-285):
  ```
  strata-peaks 1
  slot <n>
  frames <frames>
  rate <rate>
  generation <g>
  peaks <64 values, three decimals>
  ```
- Writing (`writeSlotPeaks`, `StrataWaveform.sc:70-87`): `<path>.<instanceTag>-<generation>.part` written by sclang's `File`, a folder at the path fails it, then `renameIntoPlace(partPath, path, finish)`; `finish` keeps `\written` and runs the action only if `slotChanges` is unchanged (or `current` answers true). A failed write posts and still runs the action.
- `renameIntoPlace` (`StrataWaveform.sc:221-258`): through the mover (one shell, FIFO of three lines per rename, `startPeaksMover` :142-188) when it is alive, fewer than `peaksMoverBacklog` (4, :127) renames are pending and no path holds a newline; otherwise `renameBySubprocess` (`mv -f` by `unixCmd`, a fork of sclang: 2.2-2.7 ms at 130 MB, up to 9.5 ms at 394 MB, `docs/notes/engine/waveform.md`, The mover). A rename the mover has not done in `peaksMoverTimeout` (1 s) goes by subprocess. Saves and scratch takes share the same backlog of 4.
- Lua reads it only in the clock loop (`lib/waveforms.lua:184-211`, one marked slot per frame tick), never in a draw or a poll callback; a slot is marked by `changed` (its reported seconds changed, `lib/buffers.lua`), `stale` (a take or load settled with audio, a dub's end, a failed load's undo) and every 2 s for a playable recording.
- Validation, `parse` (`lib/waveforms.lua:51-72`):
  - `if lines[1] ~= PEAKS_MAGIC then return nil end` with `PEAKS_MAGIC = "strata-peaks 1"` (:23, :54);
  - every other line matching `^(%a+)%s*(.*)$` goes into `fields[key]` (:56-59): **unknown keys are ignored**, and a key is letters only (`%a+`);
  - `tonumber(fields.slot) ~= slot` → nil (:60); `frames` and `rate` must be numbers, `rate > 0` (:61-62); `math.abs(frames / rate - S.buffers[slot].seconds) > LENGTH_TOLERANCE` (0.01 s, :24) → nil (:63);
  - every `peaks` token a number in 0-1, not NaN (:65-69), and exactly `WAVEFORM_POINTS` (64) of them (:70).
- **An unknown version** (any first line other than exactly `strata-peaks 1`, including `strata-peaks 2`) makes `parse` return nil: `read` stores `points[slot] = nil` (:94-95) and the slot draws no waveform (BUFFER's flat line, a dark-peaked grid row). No error, flash or console line.
- So: an extra line with a letters-only key under version 1 is ignored by today's parser; a version bump makes today's Lua draw nothing for that file. Lua and the engine ship together, and every load and take rewrites the slot's peaks file, so a file of the other version exists only until the slot's next load or take (the restore at start reloads every remembered slot, rewriting its file).
- `peaksContent` is what the refresh compares (`peaksUnchanged`, :290-293): anything added to the file's content is compared too.
- The engine-check area for the file is `test/engine_check/waveform.scd` (format, rising generation, order of file and report).
- `frames` and `rate` reach Lua in the file but are used only for the 0.01 s check, never stored (`lib/waveforms.lua:61-63`): the exact frame count is otherwise unknown to Lua (it has `seconds` to 0.01 from the poll, and the file's own frames and rate from `audio.file_info` in `file_length`, `lib/buffers.lua:479`).

The other file channel from the engine is `performance_active.data` (the performance area, `docs/notes/lua/performance.md`); it holds the tier, not per-slot data.

---

## 4. What a slot stores in Lua

### `S.buffers[slot]`

Initialized at `lib/buffers.lua:72-79`:
`{name = "empty", loaded, recording, finishing, restoring, settled_empty, seconds = 0, path, confirm_since, missing_path, loads_sent, pending_loads, saves_sent, pending_saves, records_sent, checking_from, checking_load, start = 0, sent_start = 0, sample_rate, file_seconds, kept_state, take_unsaved, awaiting_zero}`. Field meanings: `docs/notes/engine/buffers.md`, Audio Sources: Lua side, Buffers table, and `lib/buffers.lua:40-71`. `seconds` comes only from the poll. `sample_rate`, `file_seconds` from `audio.file_info` at each load (`file_length(path)`, `lib/buffers.lua:479`).

States: `S.lib.buffers.status(slot)`, derived only, eight cases (`finishing`, `armed`, `loop`/`dub`/`recording`, `loading`, `loaded`, `unsettled`, `missing`, `empty`); `is_free` is `empty` or `missing` (`docs/notes/lua/buffers.md`, States). The `"buffer slots"` invariant: `finishing` only with `recording`, `checking_from` only with `confirm_since`, never `settled_empty` with `loaded`, `kept_state` never while recording, `start == sent_start` unless a start reload is pending, a take name and a scratch path name the slot's own number (`docs/notes/lua/buffers.md`, Must not break and States).

### buffers.data

- Location `~/dust/data/strata/buffers.data` (`buffer_data_file()`, `lib/buffers.lua:867`).
- Value written: `remembered_buffers()` (`lib/buffers.lua:889-896`):
  ```
  {version = BUFFER_DATA_VERSION, paths = paths, starts = starts}
  ```
  `paths[slot] = S.buffers[slot].path or S.buffers[slot].missing_path or ""`, `starts[slot] = S.buffers[slot].start or 0`. Paths and starts only; never audio (`docs/notes/lua/buffers.md`, Must not break, first item).
- `BUFFER_DATA_VERSION = 2` (`lib/constants.lua:24`); version 1 (3.2) has no `starts`.
- Written only through `save_buffers_to_disk` → `S.lib.data_files.write` (`lib/buffers.lua:902-931`), a checked `.part` renamed into place, nothing when the bytes are the same. `remember()` (`lib/buffers.lua:940-954`) runs at the end of `buffer_display_changed()` and of `buffer_state_changed` when something changed, compares `encode(remembered_buffers())` with `S.buffer_file.text`, and writes 0.1 s later from one clock (#566). Rule: "A new place that changes a slot's `path`, `missing_path` or `start` must end in one of the two" (`docs/notes/lua/buffers.md`, Must not break, third item). A field not in `remembered_buffers()` is never written.
- The v1 keep-copy: with `S.buffer_file.version` set (an older file was read), the first save first copies it to `buffers.data.v1` through `keep_copy` (first free of `.v1`, `.v1.2` ... `.v1.9`); a failure there fails the save (`lib/buffers.lua:910-914`; `docs/notes/lua/buffers.md`, Must not break).
- Reading (`restore_buffers_from_file`, `lib/buffers.lua:966-1019`): through `S.lib.data_files.read` (parsed, never run); **a version other than `BUFFER_DATA_VERSION` or 1, or no `paths` table, sets the file aside** (`if (loaded.version ~= BUFFER_DATA_VERSION and loaded.version ~= 1) or type(loaded.paths) ~= "table" then ... preserve_unloadable_buffer_file()`, :982-987) to `buffers.data.bak` (`.bak.2` ... `.bak.9`), and nothing is restored. So a build that writes version 3 must accept 2 explicitly (today's test accepts only "current or 1"), and 3.6 reading a version 3 file sets it aside and starts with every slot empty (the file is kept as a backup, not lost).
- The data-file reader takes `tab.save`'s layout only; at most `max_tables` 32768 tables and 4 MB per file (`docs/notes/lua/data-files.md`, Must not break). The layout stays readable by 3.2's `tab.load`.
- A start that is not finite reads as 0 (:995-997); a start is clamped to `longest_start` of the file as it is now (:1003-1006).

### What happens to a slot's stored data on each change

| Change | `path` | `start` | `sample_rate`, `file_seconds` | Code |
|---|---|---|---|---|
| clear | nil (and `missing_path` nil) | 0 (`sent_start` 0) | nil | `clear_buffer`, `lib/buffers.lua:493-519` |
| load of a new file | the new path | the start sent (0 for the file param and the selector) | the new file's | `load_buffer`, `lib/buffers.lua:446-491` |
| start reload (`set_start`) | **the same path** | the new start | unchanged | `set_start` → `load_buffer` after 0.3 s (`docs/notes/lua/buffers.md`, The start point) |
| replace take | the scratch path `_path.audio .. "strata/scratch/buf<n>.wav"` on settle | 0 | nil | `recording_started(slot, false)`, `confirm_buffer_audio` (`docs/notes/lua/buffers.md`, The file fields) |
| playable recording (dub, loop) | the file's until "ended", then the scratch path | the file's until "ended", then 0 | the file's until "ended", then nil | `recording_started(slot, true)`, `record_state_changed` |
| a take the engine could not write | the scratch path forgotten (`take_unsaved`) | 0 | nil | `take_write_failed` (#312) |
| a failed load | put back from the load's snapshot (`previous`) | put back (`sent_start`) | put back | `buffer_load_failed`, `apply_buffer_state` |
| file missing at start | nil; `missing_path` = the path | kept with the path | nil | `restore_buffers_from_file`, `lib/buffers.lua:1010-1015` |

Facts a design keyed on what the slot holds must meet:
- **Every take of a slot has the same path** (`scratchPath(index)` in the engine, `scratch_take_path(slot)` in Lua), so a path does not identify a take's audio.
- **A start reload keeps the path and changes the audio**; on a long file it usually keeps the length too.
- A file on disk can be replaced under the same path between sessions (the restore clamps the start to the file as it is now, `lib/buffers.lua:1002-1006`).
- A 300 s file restored on a 60 s tier loads its first 60 s (`docs/notes/lua/buffers.md`, Long buffers).
- The restore's own loads write nothing (`S.buffers_loaded` is false until it ends, `lib/buffers.lua:1023-1026`).

### PSETs and scenes

- PSETs: the buffer group's params are `record_duration`, `record_level`, then per slot `buf<n>_file` (`params:add_file(..., _path.audio)`, action `load_buffer(slot, path)` with **no start**, so start 0), and the triggers `buf<n>_record`, `buf<n>_clear`, `buf<n>_save` (`lib/params_setup.lua:680-689`). norns saves a file param in a PSET (`paramset.lua:513`: every param with `save` that is not a trigger or separator); reading a PSET sets it, and norns' `File:set` runs the action only when the path differs (`~/src/norns/lua/core/params/file.lua:29-42`). So a PSET read loads each slot whose PSET path differs, from start 0; a directory path (an empty slot's `_path.audio`) loads nothing (`load_buffer` ignores it). A folder name with shell syntax is never in the param, so a PSET neither shows nor saves that slot (#559, `docs/notes/lua/buffers.md`). The record params are PSET-only (`docs/notes/lua/record.md`).
- Scenes hold, per voice, `source` (1 synth, 2-9 buffer 1-8, 10 input) and the grain params `buf_pos`, `buf_rate`, `buf_scan` (`lib/scenes.lua:125-128`), and the registered extras `loop_start`, `loop_length`, `bookmark_1..4`; never slot contents or paths ("the buffer's contents are not captured", `lib/scenes.lua:424`). A recalled scene plays whatever the slot holds now (`docs/notes/engine/buffers.md`, Audio Sources: Lua side, Scenes).

---

## 5. Positions per voice and the fractions they are in

| Value | Fraction of | Where |
|---|---|---|
| `v<i>_loop_start`, `v<i>_loop_length` | the slot's valid region (V) | `docs/notes/lua/loops.md` ("Both are fractions of the slot's valid region"); start at most 0.999, length 0.001 to `1 - start` |
| `v<i>_buf_pos` | **the voice's loop** | engine: `start = loopStart + ((min(bufPos, lastLoopPosition) + scan + spreadDraw) wrap 0..1) x loopLength` (`docs/notes/engine/loops.md:16`; `lib/engine/StrataLoop.sc:59`) |
| `v<i>_bookmark_1..4` | the valid region | `store_bookmark` stores a region position (`lib/positions.lua:213-221`); `jump` takes a region fraction |
| the playhead `S.lib.playheads.position(v)` | the valid region | `lib/playheads.lua:68-75` |
| the record head `record_head(slot)` | the valid length `max(seconds, D)` | `docs/notes/lua/playheads.md`, Owns |
| a grid cell | the region: cell c of n starts at `(c - 1) / n` | `lib/positions.lua:395-416` |
| a step's `pos` lock | the loop (it overrides `buf_pos`) | `lib/sequencer.lua:55` (`lock_params = {pos = "buf_pos", ...}`) |
| `saveBuffer`'s start and length | the valid region | `StrataFiles.sc:265-283` |

Every place that converts between a region fraction and a loop fraction, or sets the loop from region fractions:
- `S.lib.positions.jump(v, p)` (`lib/positions.lua:149-163`): inside the loop (`p >= start - 1e-6 and p < start + length - 1e-6`) `buf_pos = (p - start) / length`; **outside it `loop_start` 0, `loop_length` 1 and `buf_pos` p** (the loop is reset to the whole slot); then `t_scanReset` while running, the glide ends, the playhead resets.
- `S.lib.positions.set_loop(v, a, b)` (:167-174): `loop_start` a, `loop_length` b - a, then `jump(v, a)`.
- `whole_loop(v)` (:177-181): 0 and 1, no jump.
- `recall_bookmark(v, n)` (:183-187) = `jump(v, bookmark)`; so a bookmark outside the loop resets the loop. The sequencer's bookmark lock recalls only when the bookmark lies inside the loop (`bookmark_in_loop`, `lib/sequencer.lua:406-413`), "where a recall moves only buf_pos (outside, lib/positions.lua's jump would reset the loop)".
- `store_bookmark(v, n)` (:213-221): the playhead, or, stopped, `start + buf_pos x length` (loop to region).
- `row_context` (:501-507): the head shown for a stopped voice is `start + buf_pos x length`.
- `S.lib.playheads.position(v)` (`lib/playheads.lua:68-75`): `start + ((buf_pos + phase) % 1) * length`.
- `S.lib.playheads.spread(v)` (:81): `grain_spread x loop_length` (a loop width to a region width).
- `grid_key` (`lib/positions.lua:395-416`): a press `jump(v, (cell - 1) / cells)`; a two-key press `set_loop(v, (low - 1) / cells, high / cells)`, both through `S.lib.quantize.schedule("position<v>", ...)`.
- BUFFER's waveform (`lib/pages/buffer.lua:493-503`): a column's middle inside `[loop_start, loop_start + loop_length)`.
- `save_buffer_loop` (`lib/buffers.lua:615-625`): the loop's start and length, clamped, as `saveBuffer`'s region fractions.
- `S.lib.bookmarks.recall` and `is_set` (3.4's interface, `lib/bookmarks.lua`): never create a node (`docs/notes/lua/bookmarks.md`).

**Code wins (Lua estimate against the engine), `buf_pos` 1**: `docs/notes/lua/playheads.md` says "`buf_pos` 1 is the loop's start again, as the engine's `Phasor` wraps", and the code does that (`(buf_pos + phase) % 1`, `lib/playheads.lua:74`); the engine holds `bufPos` under `lastLoopPosition` (0.999999, `StrataLoop.sc:17, 59`), so `bufPos` 1 is the loop's **last** start (#363, `docs/notes/engine/loops.md:27`). At `buf_pos` 1 the playhead Lua draws (BUFFER, grid row) is at the loop's first cell while the engine plays at its last.

What changes a slot's valid region length (and so the meaning of every region fraction): a load taking effect (0, then the new frames: `applyLoad`), a start reload (a new `startFrame`; usually the same length on a long file, but different audio), a replace take (0 at its preparation, then F frames: `endTake`), a playable recording longer than the slot (`max(V, D)` at the arming, `takeArmed`, `StrataRecord.sc:539-545`), a clear (0), a failed server read (0, `StrataBuffers.sc:327-334`), and at the next start a tier change (a shorter `bufferSeconds`). A playable recording shorter than the slot keeps V but changes the audio inside it continuously.

---

## 6. The BUFFER page

**Views**: one. There is no second view; the file selector (`fileselect`) replaces the whole page while `S.BUFFER_PAGE.file_selector_open` is set (`docs/notes/lua/pages/buffer.md`, Must not break, first item).

**Fields** (`BUFFER_FIELDS`; cursor `S.buffer_page.field` 1..11, four visible, scrolling): `v<sel>` (source), `rec` (record source), `dur`/`len`, `lvl`, `fb`, `loop`, `thr`, `sync`, `bm` (bookmark recall), `start` (the file's start point), `fric` (`docs/notes/lua/pages/buffer.md`, Cursors). The slot cursor `S.buffer_page.slot` 1..8, three rows visible.

**Controls** (`docs/notes/lua/pages/buffer.md`, Controls; `docs/user/pages/buffer.md`):
- E1: the page (global, `docs/user/controls.md:24`).
- E2: the slot cursor. ALT+E2: the field cursor (`alt_enc` returns true for E2 only).
- E3: edit the field; ALT+E3 fine adjustment (the `bm` field: recall the shown bookmark again; `start`: the band's step).
- K3 press (and the arc button): `record_buffer(slot)` (record, stop early, cancel while armed). No hold meaning: it acts at the press.
- K2 release: under 0.5 s the file selector; held 0.5 s or more a random file (`S.lib.files.random_into`).
- ALT+K2 release: under 0.5 s clear; held, fill every empty slot.
- ALT+K3 release: under 0.5 s save the slot; held, save the loop region (trim).
- **Free combinations: none in use-free form.** K3 has no hold form (it acts at the press); "K3 while K2 is held just records"; "the K2+K3 save gesture is gone (ALT+K3 saves)" (`docs/notes/lua/pages/buffer.md`, Must not break and Controls). The field list can take more fields (it scrolls).

**Layout** (`S.BUFFER_PAGE`, `lib/pages/buffer.lua:45-86`; drawing :473-562):
- Header y 8 and hint row y 62 are `redraw()`'s (AGENTS.md).
- Divider x 56, y 10-52.
- Left column x 0-54: field rows at baselines y 16, 24, 32, 40; the input meter at y 49 (segments y 44-49, x 17-48).
- Waveform: `S.lib.waveforms.bins(slot, 64)`, one column per point at x 60-123 (`wave_x` 60, `wave_columns` 64), centered on y 19, half-height `round(peak x 8)`, inside y 11-27; level 8 inside the selected voice's loop and 3 outside when it reads the slot, 6 when it does not; an empty slot a flat line at y 19, level 1.
- Heads at `wave_x - 1 + cell_of(fraction, 64)`: a voice's head a line y 11-27 (selected 15, others 11), its spread on y 28 at 4; the record head dotted y 11-27 at 12.
- Bookmark ticks: 1x2 px at y 29-30, level 6, the last recalled 15; y 31 kept clear.
- Slot rows at baselines y 37, 44, 51 (slot number x 59, name x 65, length right-aligned at x 124), the scroll marker at x 127 (y 31-52).
- Unused screen (approximate, from these constants, assuming norns' font glyphs about 5 px above the baseline): a band of about y 52-56 under the slot rows and the meter across the screen; x 0-55 at y 50-56; x 124-126 beside the waveform (y 11-30); x 57-59 between the divider and the waveform. The 64-column waveform and its 17 px height are fixed; no region larger than a few pixel rows is empty.
- Every point the waveform has is one of `WAVEFORM_POINTS` (64): BUFFER draws exactly the 64 points, one per pixel column. `bins(slot, n)` for n above 64 repeats points (`lib/waveforms.lua:149-161`).

**The arc's BUFFER rings** (`lib/arc/buffer.lua:16-27`; `docs/notes/lua/arc-pages.md`, BUFFER):
- Plain: ring 1 `v<sel>_buf_pos` (with the scrub glide, `scrub_turned`), ring 2 `loop_start`, ring 3 `loop_length`, ring 4 `buf_scan`.
- ALT: ring 1 `buf_pos` again and it holds the voice's scan (holder `"arc"`) until ALT comes up; ring 2 `buf_rate`; ring 3 `scrub_friction`; ring 4 `record_feedback` (always level 12).
- Rings at 15 for a buffer-sourced voice, 4 otherwise. The arc button records (`arc_button`).

---

## 7. The grids' position pages (page 5)

Constants: `GRID_PAGES = {patterns = 1, faders = 2, scenes = 3, sources = 4, positions = 5, count = 5, position_cells = 16}` (`lib/constants.lua:166-167`). Every layout's position row has 16 cells (a 1/16 of the region each); keys go through `S.lib.positions.grid_key`, `strip_key`, LEDs through `grid_level`, `strip_level`. Repainted by the playhead clock (15 Hz) when `display_signature()` changes (`docs/notes/lua/playheads.md`).

LED levels in use on page 5 (`lib/positions.lua:20-27`): cells outside the loop 1 + round(peak x 2) (1-3), inside 4 + round(peak x 4) (4-8), a held key 11, the record head 13, the playhead 15; strip keys: bookmark 6, last recalled 10, stored (pressed with store) 15, store/hold down 15 and up 4, whole 15 or 4, a waiting bookmark blinking 15/2 every 4 ticks. A voice that reads no buffer, or a slot with no audio, is 0 (dark). **Cell levels not used on a position row: 9, 10, 12, 14.**

| Layout | Page 5 keys | Free on page 5 |
|---|---|---|
| 256 | rows 1-7: voice v's 16 cells (`lib/grid/layout_256.lua:280-289, 460-466`); rows 9-15: voice (y - 8)'s strip, columns 1-4 bookmarks, 6 store, 7 hold, 8 whole (`strip_key_columns`, :47); row 8 and row 16 as on pages 1-4 (row 8: 1-4 play, 5-8 tempo, 12 the positions page key, 13-16 pages 1-4: :304-312, :403-415, :570-580; row 16: 1-7 lock, 8 the freeze hold, 9-15 copy/paste, 16 clear) | rows 9-15, columns 5 and 9-16 (9 keys per voice, 63 in all); row 8, columns 9-11 (unused on every page) |
| 128h | rows 1-7: voice v's 16 cells; row 8 the control row (1-4 play, 5-8 pages, with column 8 toggling 4 and 5; 9-15 voice on/off; 16 next grid voice) (`lib/grid/layout_128h.lua:175-191, 194-233`). The strip is on **page 4** (rows 5-6, columns 13-16: bookmarks on row 5, store, hold, whole on row 6, :41-45), for the grid voice only | none. On page 4: row 6 column 16, row 7 columns 13-16, column 11 (a light only) |
| 128v | columns 1-7: voice x's 16 cells down rows 1-16 (`lib/grid/layout_128v.lua:155-160`); column 8: rows 1-7 voice on/off, 8 the page key (cycles `PAGES.count`), 9 play, rows 10-16 the grid voice's strip (1-4, store, hold, whole: :140-142) | none |
| 64 | rows 1-2: the grid voice's 16 cells (row 1 cells 1-8, row 2 cells 9-16); row 3 the strip (columns 1-4 bookmarks, 6 store, 7 hold, 8 whole); row 7 columns 1-7 select the grid voice (15 selected, 6 a buffer voice, 2 other); row 8 as on the steps views (`lib/grid/layout_64.lua:25-31, 101-104, 157-160`). Reached by a 0.5 s hold of row 8 column 1, which cycles steps 1-8, steps 9-16, positions | rows 4-6 (24 keys, dark), row 3 column 5 |

A voice's row: 16 cells on every layout; the 256 and 128h show all seven voices at once, the 128v all seven as columns, the 64 one voice (the grid voice).

The 128v also lights the grid voice's column one level up (`grid_level + 1`, at most 15, #444); the 128h's page 4 marks the grid voice at column 11.

**Other grid pages per layout** (`docs/notes/lua/grid/*.md`): 256: 1 patterns (with 3.4's recorders, mutes, banks, macros on rows 9-13), 2 parameter faders, 3 scenes (recall, fade, save, sequencer lengths, recorders, morph, A/B, XY pad), 4 buffers/FX/sources/freeze, 5 positions. 128h: 1 patterns, 2 faders, 3 scenes, 4 sources (with the strip), 5 positions (from page 4's key). 128v: the same five, cycled by (8,8). 64: steps 1-8, steps 9-16 (both page 1) and positions (page 5); no sources page. `GRID_PAGES.count` is 5 and the 128v's page key cycles `page % PAGES.count + 1` (`lib/grid/layout_128v.lua:137`), so a sixth page joins its cycle. Free page keys: the 256's row 8 columns 9-11; the 128h's row 8 has none free (columns 5-8 are pages 1-4, page 5 is reached through page 4's key).

Free regions on other pages (from the notes): 256 page 3 rows 11-15 columns 1-11 (dark), page 4 rows 9-15 columns 11 and 13-16, row 9 column 12 of page 1; 128h page 4 as above.

---

## 8. Normalize

- **What the 64 peaks hold**: the largest absolute sample of each bin across both channels, clipped to 1. For a load: `peaks[bin] = peaks[bin].max(chunk.peak.min(1.0))` (`StrataFiles.sc:113`), `Signal.peak` being the largest absolute value. For a replace take: the largest `|sample|` written per bin, after the record level and envelope, `min(1)` (`StrataRecord.sc:126-127`). For a playable recording: `min(1, old x feedback + new)`, an upper bound (section 2).
- Clipped at 1 on every path: a float file with samples above 1, or a take recorded at `record_level` up to 2 (`lib/params_setup.lua:673-678`), reads 1.000 in its bins while the buffer holds the larger floats (the buffers are float, `docs/notes/engine/files.md`, File writes: "a take can hold samples beyond ±1").
- Resolution in the file: three decimals (`peakText`, `StrataWaveform.sc:54-57`), so a bin under 0.0005 reads 0.000 (about -66 dBFS) and steps are 0.001 (one step is about 6 dB at 0.002). sclang keeps full float values in `areaState[\waveform][\peaks]` and the peak buffer.
- **The slot's overall peak is not known in Lua today**: no field holds it; it is derivable as the largest of `S.lib.waveforms.peaks(slot)` (`lib/waveforms.lua:143-146`), which is nil until the file is read and valid. Nothing computes it today (**not found** elsewhere).
- No RMS or loudness is computed anywhere (**not found**).
- A recorded take's peak comes from the record synth's peak bins (server peak buffer, read by `b_getn`), never from a scan of the audio; a take restored at the next start gets a load's scan.
- Where a playback gain may go (engine constraints in AGENTS.md; `docs/design/3.7-facts/engine.md` §2): no grain SynthDef has a voice-level amp; a grain synth's only gain is the note's (`noteAmp` and the accent); the stage's level comes after the voice filter, on the other path only (AGENTS.md, Invariants, "One grain path" and "One persistent stage per voice").

---

## Code wins

1. `buf_pos` 1: `docs/notes/lua/playheads.md` (and `lib/playheads.lua:74`, `% 1`) put the playhead at the loop's first start; the engine plays the loop's last start (`StrataLoop.sc:17, 59`; `docs/notes/engine/loops.md:27`, #363). The Lua estimate and the engine disagree at that one value.

No other disagreement between the notes and the code was found in this area: every rule checked in `docs/notes/engine/buffers.md`, `files.md`, `waveform.md`, `record.md`, `freeze.md` and `docs/notes/lua/buffers.md`, `waveforms.md`, `positions.md`, `loops.md`, `bookmarks.md`, `pages/buffer.md`, `grid/*.md` matches the cited code.

## Not found

- A bad-sample (NaN, inf) check at load.
- Any Pi measurement of a load, a decode check or the peak scan.
- Any onset, transient or slice code.
- The slot's overall peak, an RMS or a loudness figure anywhere in Lua or the engine.
- The reply-size limit of a `b_getn` / `b_setn` of thousands of floats on norns (not checked).
- Per-call cost of `SoundFile.readData` on small chunks (not measured).

## Constraints a design must meet (as stated by the code and notes)

- Engine to Lua: one float per poll message; anything longer goes by file, written to a `.part` and renamed through `renameIntoPlace` (the mover; a backlog of 4 shared with saves and peaks refreshes), read by Lua only in a clock loop, never in a draw or poll callback, and validated before use.
- A length report never precedes the peaks file it describes (`writeSlotPeaks`' action; `announcedBufferState`).
- sclang sample work: fresh read arrays, no function per sample, no unbounded List, `yieldToCommands` between chunks, `areaCall` for kept closures; `fileDecodes` and its callees are scanned by two structure tests that ban `.abs`, `copyRange`, `collect`, `maxItem`, `minItem`, `.sum(`, `.do(` and others by name.
- Server analysis: no `LocalBuf`; FFT buffers are sclang-allocated server buffers (the high tier's spectral pairs are in use by freeze); a record synth stays at or under 24 KB of the pool; a new node per voice or slot needs the memory budget re-measured.
- buffers.data: version check accepts only the current version and 1 (extend it); a new field must be in `remembered_buffers()` and its changes must end in `buffer_display_changed()` or `buffer_state_changed`; written only through `S.lib.data_files.write`; an older format kept as `.v<n>` before the first save; 3.6 sets a newer-version file aside.
- A take's path is the same for every take of a slot; a start reload keeps the path; scenes never reference slot contents; a PSET loads slot files from start 0.
- Positions: slices in region fractions meet a voice whose `buf_pos` is in loop fractions; `jump` outside the loop resets the loop to the whole slot.

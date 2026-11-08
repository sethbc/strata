## Must not break

- **Freeze acts through the voice's ring writer, its grain synth's ring and the `freeze` control, never by stopping a grain synth.** The `freeze` and `freezeMode` handlers act, then return false, so `setGrainParam` also stores the control and sends it: `freeze` is what stops a slot's scan (`scanRate`) and moves a frozen ring's read point (`ringScanOffset`).
- **Fade before overwriting a ring.** The input copy is the one write into a voice ring that is not its writer's: the voice ring's readers (`voiceRingReaders`) get `ringLevel 0` and the copy waits `bufferFadeWait` when any plays, at once otherwise. Every step after a wait runs only while `ringChanges[voice]` is unchanged and no later copy started: an unfreeze, refreeze or source switch wins. The faded readers get `ringLevel 1` back once the copy is in, or abandoned, by the latest copy only.
- **One writer per voice.** Spectral and an input copy's writer change by `Synth.replace` (the old node freed in the same server step); `synths[ringWrite<i>]` and `areaState[\rings][\writers]` always name the running one, so the rings area's `stop` frees it. Writers are `effectKeys`: plain messages (`run`, `replace`).
- **Spectral only on the high tier, and only for a ring.** `\strataRingWriteSpectral` is added only when `tier == \high`; `freezeModeFor` gives `\hold` on standard and for a buffer voice whatever `freezeMode` says.
- **No `LocalBuf`, in this def or any engine SynthDef.** Building a `LocalBuf` into a SynthDef corrupts sclang 3.13's garbage collector (norns runs 3.13), and sclang aborts a little later wherever the collector next runs: in CI the engine check died in the buffers, files or performance area. The spectral writer's FFT buffers are server buffers (`\spectralBuffers`, one pair per voice on the high tier, passed as `fftL`/`fftR`); one writer per voice means a pair is never shared. `test/unit/structure_test.lua` fails on any `LocalBuf` in the engine source outside comments.
- **History is 0 inside a frozen input copy.** The freeze area wraps the grains area's `history` handler: while the voice is frozen on the input it keeps the value and sends nothing; the unfreeze sets the grain synth back to the input ring at that history.
- **A switch unfreezes.** `replaceGrainSynth` calls `unfreezeVoice` first; it puts the kept `freeze` control at 0, so the new grain synth starts unfrozen (Lua's `source_change` hook then sets `v<i>_freeze` 0 too).
- **Real-time memory.** A spectral writer takes about 80 KB of the pool (two 2048-frame FFT chains; their FFT buffers are server buffers, outside the pool); seven, on the high tier's worst case, leave about 4.8 MB free (the `memory` area's high run engages spectral freeze on every voice and requires 4 MB).

## The freeze area

`lib/engine/StrataFreeze.sc`, order 110. `areaState[\freeze]`, per voice:

| Key | What |
|-----|------|
| `\frozen` | Boolean |
| `\mode` | `\hold` or `\spectral` while frozen, else nil |
| `\source` | the source it froze (a source changed while the voice was stopped is unfrozen and frozen again) |
| `\copied` | an input voice's copy is in its ring and its grain synth reads it |
| `\copies` | the number of the voice's latest input copy |
| `\faded` | the ring readers a pending copy set to `ringLevel 0` |
| `\inputReaders` | (one for all voices) input grain synths set to read their voice ring → `(voice, until)`: `until` nil while they do, the time they stop counting once set back |
| `\spectralBuffers` | (high tier only, else empty) each voice's `[left, right]` FFT buffers of `spectralFrames`, for its spectral writer; the area's `free` frees them |

Methods: `spectralFrames` (2048), `spectralDither` (0.00001), `freezeLeaveSeconds` (`grainMaxSeconds + ringReadMargin`), `scanRate(bufScan, freeze)`, `ringScanOffset(bufScan, freeze)`, `freezeVoice(voice)`, `unfreezeVoice(voice)`, `setFreezeMode(voice, value)`, `freezeModeFor(voice)`, `frozenOnInput(voice)`, `voiceRingReaders(voice)`, `ringWriterFor(voice)`.

## What each source holds

| Source | hold | spectral (high tier) |
|---|---|---|
| synth | the voice's writer is paused (`/n_run 0`); the phase bus keeps its last frame, so the grains read the frozen ring | the writer is replaced by `\strataRingWriteSpectral` reading the voice bus: the ring keeps receiving one held spectrum |
| input | the voice's writer is paused and the 4 s of the input ring ending at the voice's read point (the head minus `ringReadMargin + history`) are copied into its ring (one `/b_gen copy` per channel, two when the span wraps the input ring's end), oldest first from frame 0; the voice's phase bus is set to 0 (the copy's end) and the live grain synth gets the voice ring, its phase bus and history 0 with a `set` | the same copy, then the paused writer is replaced by a spectral writer of `inputBus`, starting from the copy's end |
| buffer | `scanRate` is `bufScan × (1 − freeze)`: the position holds while spread, pitch and the draws still move | not offered: holds |

- **Unfreeze** reverses each step. A paused writer resumes from its own phase (the grains may cross the seam between old and new audio once). A replaced writer (spectral, or an input copy's) is replaced by a `\strataRingWrite` of the voice bus, which starts from the phase bus: after an input copy that is the copy's end, so it writes over the copy's oldest audio first. An input voice's grain synth is set back to the input ring at the voice's history.
- **The frozen read point** (`ringScanOffset`, added to a ring grain's lookback): 0 unfrozen. Frozen, a ring's head no longer moves, so a grain must start at least its own length behind it or it reads across the seam into the ring's oldest audio: `grainMaxSeconds` (0.5 s) more covers any grain (`max(r − 1, 0) × dur` is already in the lookback). Then `bufScan` moves the read point back through the ring, in ring lengths per second (a negative scan moves it forward), from where the freeze began, wrapping (a `Phasor` reset as `freeze` rises): moving back, the grains play about 3.5 s of continuous audio before the read point crosses the seam into the newest audio again, once per 4 s of travel. Frozen grains therefore play from about half a second before the freeze point. Spectral keeps the offset: a spectral writer's ring still moves, and 0.5 s back is real audio (the voice's, or the input copy's).
- **The spectral writer** has `\strataRingWrite`'s controls and phase; each channel goes through `FFT(fftL or fftR, …, 0.5)` (the voice's 2048-frame `\spectralBuffers`, which `replaceRingWriter` passes) → `PV_MagFreeze` → `IFFT`. It writes the input itself until the analysis has run two windows (the IFFT's latency; `PV_MagFreeze` then holds a real spectrum), then crossfades to the held spectrum over 10 ms, so the ring never gets a gap. Its input and output go through `zeroBadValues`. The analysis input gets a dither of about −100 dBFS (`spectralDither`, white noise): on exact digital silence `PV_MagFreeze` would otherwise hold zero phases and buzz at the hop rate; under real sound it is inaudible.
- **A mode change while frozen** (`freezeMode`) freezes again in the new mode: unfreeze, then freeze.
- **A freeze while frozen** on the same source and mode changes nothing but points the live input grain synth at the copy again (a grain synth `voiceOn` started reads the input ring; Lua's sync sends `freeze` again after `voiceOn`). A voice frozen on another source (it changed while the voice was stopped, so no switch unfroze it) is unfrozen first.

## The input copy and the ring readers

`copyInputToVoiceRing` runs in a routine (`SystemClock`):
1. it counts the copy (`\copies`) and finds the voice ring's readers (`voiceRingReaders`), giving each `ringLevel 0` (added to `\faded`);
2. with readers it waits `bufferFadeWait`;
3. it reads the input writer's frame from its phase bus, sends the copies and waits for them (`server.sync`);
4. then `holdVoiceRing`: the voice's phase bus to 0, the spectral writer for spectral, `\copied`, and the grain synth pointed at the copy;
5. the latest copy gives the faded readers `ringLevel 1` back.

Steps 3 and 4 run only while the copy is current (`ringChanges` unchanged and no later copy).

`voiceRingReaders(voice)`: the playing `\strataGrainRing` synths `ringReaders` maps to the voice, but not the live input grain synth reading the input ring; plus the input grain synths in `\inputReaders` until `freezeLeaveSeconds` after they were set back (their grains already playing still read the voice ring). `ringReaders` itself keeps every `\strataGrainRing` (the rings area's rule), input ones too; an earlier input grain synth still fading counts as a reader here, so at worst a copy waits for nothing. A refreeze within `freezeLeaveSeconds` of an unfreeze therefore finds the live synth among the readers: it fades (a short dip), the copy waits `bufferFadeWait`, and its level comes back with the copy.

## The engine check (`test/engine_check/freeze.scd`)

It reads a timecode, as the rings area does (a check synth writes the seconds since it started, left, and 1, right, into voice 1's bus and the input bus, each switchable, and the seconds to a private bus; a grain synth with a rectangular envelope plays left/right = the time its audio was written). It checks:
- the area's state, that `freeze` feeds a UGen in both grain SynthDefs, and `scanRate`;
- a frozen synth voice keeps sounding after its voice bus falls silent (the writer paused, the reads from about 0.5 s before the freeze); at `bufScan` 1 each grain starts further back (every step between grain starts is backward) and the start jumps to the newest audio once per 4 s of travel (the seam); unfreeze resumes the live ring (lookback back to the margin);
- spectral on standard holds (the writer paused, no spectral writer); a switch unfreezes (the writer runs, the new grain synth at `freeze` 0);
- an input voice with no other reader is copied at once and its grain synth reads the copy at history 0; history 2 holds the timecode from 2 s back (and 0.5 s more); history stays 0 inside the copy and is kept; the live input grain synth is a ring reader while frozen and 0.2 s after unfreeze, not 0.7 s after;
- with `bufferFadeWait` 0.4 s: a refreeze inside that window fades the live synth before copying and restores it; a switch to the input leaves the synth-source grain synth fading, and the copy waits for it; an unfreeze inside the wait wins (no copy: the zeroed voice ring stays zero); a frozen input voice switched to its synth is unfrozen (its writer reads its voice bus and runs);
- a buffer voice on a 1 s ramp: the scan stops while frozen (a read span of 0.05 s, the grain's), and spread still moves it;
- on a second engine on the high tier: it adds `\strataRingWriteSpectral` (with `\strataRingWrite`'s controls); 20 spectral freeze toggles leave one writer per voice (`synths` and `\writers` naming the running one, the phase moving); a spectral writer frozen on silence writes nothing audible (ring peak under 0.001); spectral on an input voice copies, then writes the held input into the voice ring its grain synth reads; a mode change while frozen freezes again in the new mode.

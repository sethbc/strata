## Must not break

- **Every draw is a `TRand`/`TIRand` on the grain trigger feeding a `GrainBuf` input** (rate, pan, duration), so `GrainBuf` latches it with the grain: a draw never moves a sounding grain, and none takes real-time memory.
- **The defaults are 3.1's sound, exactly.** With `reverseProb` 0, `pitchJitter` 0, `intervalCount` 0, `quantize` 0, `panJitter` 0 and `sizeJitter` 0 a grain's rate is `pitchShift × bendRate`, its pans -1 and +1 and its length the grain size. The engine check measures rate 1 and the 6 dB channel difference of a 0.5/-0.25 file at those values.
- **Quantize comes before bend and crossmod**: `bendRate` multiplies the quantized ratio, so pitchbend and frequency crossmod still bend a quantized voice.
- **Size jitter never makes a grain longer than `grainMaxSeconds` (0.5 s)**: `grainBody` caps `grainDur`'s result. The rings' lookback bound (`docs/notes/engine/rings.md`) relies on it.
- **`scaleBuffer`'s bufnum never changes.** It is allocated once in the scale area's `allocState` (before every area's `addDefs`), and `grainRate` builds it into both grain SynthDefs as a constant. `setScale` only rewrites its 12 frames. SynthDefs are named per server, so the last engine built owns the grain defs: on norns one engine runs at a time, but the engine check's second engines (`h.startEngine`) re-add them with their own buffer, so `variation.scd` rebuilds them for `h.engine` (`addGrainDefs`) before it plays grains.
- **`setScale` ignores a root outside 0-11 or a mask outside 1-4095** (an empty mask would leave no tone to land on); the scale stays as it was.
- **`intervalCount` is a whole number 0-8** (`intervalCount.round.clip(0, 8)`, which the Lua stub reads as its range).

## The variation area

`lib/engine/StrataVariation.sc` (order 90) holds no state, defs or commands. It fills the three hooks both grain SynthDefs call in `grainBody` (`lib/engine/StrataGrainDefs.sc`, `docs/notes/engine/grains.md`), each on the grain trigger `trig`:

| Hook | Result |
|------|--------|
| `grainRate(trig, pitchShift, bendRate, vary)` | the signed rate: `ratio × bendRate × (-1 with probability reverseProb)` |
| `grainPan(trig, panJitter)` | `u × panJitter`, added to both channel buffers' pans (-1 and +1) and clipped at ±1 by `grainBody`, on top of the slow `Balance2` wander |
| `grainDur(trig, grainSize, sizeJitter)` | `grainSize × 2^(u × sizeJitter)`, capped at 0.5 s by `grainBody` |

`u` is a fresh `TRand.ar(-1, 1, trig)` for each draw. `grainRate`'s `ratio`:
1. `offset = u × pitchJitter + interval` semitones. `interval` is one of `interval1..intervalCount`, picked by `TIRand.ar(0, intervalCount - 1, trig)` (summed with `BinaryOpUGen('==', pick, index)`), taken with probability `intervalProb` (`TRand.ar(0, 1, trig) < intervalProb`), and 0 while `intervalCount` is 0.
2. Not quantized: `pitchShift × 2^(offset / 12)`.
3. Quantized (`quantize` > 0.5, chosen by `Select.ar`): `quantizedRatio(pitchShift, offset, scaleNote)` (below).

The controls are the grain SynthDefs' own (declared by 1b with neutral defaults): `reverseProb`, `intervalProb` (0-1), `pitchJitter` (semitones), `panJitter`, `sizeJitter` (0-1), `interval1..8` (semitones), `intervalCount`, `quantize` (0/1) and `scaleNote` (a fractional MIDI note, default 60). Lua sends them through `setGrainParam`, like any grain param, and the engine keeps them in `grainControls` for a replacement grain synth.

## The scale area

`lib/engine/StrataScale.sc` (order 80) holds the one scale every quantized voice lands on.

`areaState[\scale]`:

| Key | What |
|-----|------|
| `\buffer` | `scaleBuffer`: 12 mono frames, one per pitch class (0 = C), each the offset (-6..6 semitones) to the nearest tone of the scale, a tie going down |
| `\root`, `\mask` | the last valid `setScale` (`scaleRootAndMask`): 0 and `chromaticMask` (4095) until one arrives |
| `\offsets` | the 12 offsets written into the buffer |

- **`setScale(root, mask)`** (`"ii"`): `mask` bit k is the pitch class k semitones above `root`. `scaleOffsets(root, mask)` tries the offsets 0, -1, +1, -2, +2, ... -6, +6 for each pitch class and takes the first in the scale, so ties go down (in C major C# → C, F# → F; in D major C → B). The buffer is rewritten with `setn`; grain synths read it per grain, so a scale change reaches the next grains.
- The default is chromatic (4095: every offset 0), which is Lua's scale off. Lua sends `setScale(root - 1, mask)` from the `scale` and `root` actions (`docs/notes/lua/variation.md`).
- **`quantizedRatio(pitchShift, offset, scaleNote)`**: `n = scaleNote + 12 × log2(pitchShift) + offset`, `q(n) = round(n) + scaleBuffer[round(n) mod 12]` (an `Index.ar` of the buffer), and the ratio `2^((q(n) - scaleNote) / 12)`. The grain lands on a scale tone measured from the voice's reference note: a synth voice's `freq` as a MIDI note, or the root + 60 for a buffer or input voice (whose key is unknown). A buffer voice's `bufRate` (and so its MIDI notes) multiplies outside the quantize, in `slotGrainReader`.

## Checks

`test/engine_check/variation.scd` reads grain rates and lengths from a timecode in voice 1's ring (as `rings.scd` does), logging each grain's rate and length into two buffers when it ends:
- every variation control feeds a UGen in both grain SynthDefs;
- the scale buffer starts chromatic; C major and D major fill the expected offsets; a bad root or mask changes nothing;
- the defaults play rate 1; `reverseProb` 1 plays the timecode backward (rate -1); `pitchJitter` 12 keeps rates in 0.5-2 and spreads them; quantize (C major from C4) lands every grain on a whole C major semitone; the octaves set gives only rates 0.5, 1 and 2, all three; `intervalProb` 0 plays rate 1 only; `sizeJitter` 1 on 0.5 s grains never passes 0.5 s;
- pan, on a buffer voice: at zero jitter a 0.5/-0.25 file keeps its 6.02 dB channel difference (within 0.5 dB) and a left-only file stays left; at `panJitter` 1 the left buffer's grains reach the right channel but never past the center.

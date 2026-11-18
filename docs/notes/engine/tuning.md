## Must not break

- **One table, `scaleBuffer`, whose bufnum never changes.** It is allocated once in the scale area's `allocState` (before every area's `addDefs`), with `tuningTableFrames` (4096) frames, and `grainRate` builds its bufnum into both grain SynthDefs as a constant. `setScale`, `setTuning` and `setTuningTone` only rewrite its frames. On norns one engine runs at a time; the engine check's second engines re-add the grain defs with their own buffer, so `variation.scd` and `tuning.scd` rebuild them for `h.engine` (`addGrainDefs`) before they play grains; `tuning.scd` rebuilds the stage with them (`addVoiceMixDef`), since the modulation area, after it in its shard and after freeze's second engine, checks that the three defs' descs are one engine's.
- **Frame f holds the allowed tone nearest note `tuningTableLow + f / tuningTableResolution`** (-100 to 309.5, ten frames a semitone), a tie going down: the pitch, as a fractional MIDI note, that a quantized grain lands on. In the default (twelve equal steps, the scale off) every frame is a whole note, exactly. A buffer voice's quantized pitch reaches -84 to 211 (its file's key, its rate and the pitch shift, each ±24): the range covers it; past either end `Index` clips to the edge frame.
- **The quantize is one `Index.ar`** of the frame nearest the grain's note, `quantizedOffset(pitchShift, offset, scaleNote)` (same signature as 3.7's, so `StrataVariation.sc` is unchanged): `round((n - tuningTableLow) × tuningTableResolution)`, `round` first because `Index` truncates. A grain lands exactly on a tone; the point where it changes tones moves by at most a twentieth of a semitone.
- **The mask applies only in a tuning of twelve tones to an octave** (`tuningAllowed`: twelve tones and a period within `tuningOctaveTolerance` of `octaveCents`); in any other every tone is allowed and `setScale`'s mask changes nothing (its root still transposes).
- **The table is built with Signal primitives** (`tuningTable`, pure): the one sclang loop is a `while` over the boundaries between neighboring allowed tones (at most 129), each step one primitive pass over every frame; never a function per frame (a structure test, #131). It goes out as **one `/b_setn` Array** (`tuningTableMsg`, `listSendMsg`), never `Buffer.setn` (whose `setnMsgArgs` adds every value in sclang): one message, so no grain reads half a table. At the start it is the buffer's completion message.
- **A bad command or an incomplete or broken set keeps the old tuning.** `setTuning(count, period)` takes count 1-`tuningMaxTones` (a whole number) and a finite period of `tuningMinPeriod`-`tuningMaxPeriod` cents, and begins a set (dropping any set begun before); anything else prints one line and leaves a set begun as it was. `setTuningTone(index, cents)` takes index 0 to count - 1 of the set begun and finite cents from 0 to below its period; anything else (no set begun included) prints one line. When every index has arrived (in any order; a repeated index overwrites) the set is checked: tone 0 is 0 and each tone above the one before. A whole set replaces the tuning and rebuilds the table; a broken one prints one line and is dropped. An incomplete set changes nothing. `setScale` ignores a bad root or mask silently, as 3.7 did.
- **The engine starts in twelve equal steps, chromatic from C** (`allocScaleBuffer`), which is Lua's default tuning, scale and root, so a default start sends none of them (#460's rule, 3.8 ruling 42; a docs test compares the start with `TUNING.default` and the params' defaults).

## The scale area

`lib/engine/StrataScale.sc` (order 80) holds the one tuning and scale every quantized voice lands on, and the reference notes the grain synths quantize around.

`areaState[\scale]`:

| Key | What |
|-----|------|
| `\buffer` | `scaleBuffer`: the table, `tuningTableFrames` mono frames |
| `\root`, `\mask` | the last valid `setScale` (`scaleRootAndMask`): 0 and `chromaticMask` (4095) until one arrives |
| `\tones`, `\period` | the tuning (`tuningTonesAndPeriod`): cents from tone 0 (the first 0, ascending) and the period in cents; twelve equal steps of 1200 at the start |
| `\pending` | nil, or the set `setTuning` began: `(count:, period:, tones: Array.newClear(count), received:)` |
| `\notes` | Lua's reference note per voice (`scaleNote`) |
| `\postIgnored` | nil, or a function the engine check sets to collect the ignored commands' lines |

The constants are methods (`tuningMaxTones` 128, `tuningMinPeriod` 100, `tuningMaxPeriod` 4800, `octaveCents` 1200, `tuningTwelve` 12, `tuningOctaveTolerance` 0.001, `tuningRootKey` 60, `tuningTableFrames` 4096, `tuningTableLow` -100, `tuningTableResolution` 10), each mirrored in `lib/tuning.lua`'s `TUNING` (`docs/notes/lua/tuning.md`).

**Degrees and keys.** Degree 0 is note `tuningRootKey + root`; the tones repeat every period up and down from it. `setScale`'s mask bit k is degree k, so in twelve equal steps it is the pitch class k semitones above the root, as 3.7's was.

**The construction** (`tuningTable(tones, period, root, mask)`): the allowed tones (`tuningAllowed`) with one more either side, a period away; each frame's cents from degree 0 (`frame × 100 / tuningTableResolution + (tuningTableLow - rootNote) × 100`, a series made with `putEach`), shifted by whole periods so every value is positive, then split into the period's start and the cents into it (`mod`); the tone starts at the lowest and, for each boundary, gains the gap to the next tone where the frame lies above the boundary's midpoint (`sign.max(0)`). The pitch is `(start + tone) / 100 + rootNote`. Twelve equal steps give exact whole notes (every value is a whole number of cents); a just or non-octave tuning lands within about 1e-5 semitone (the buffer is float32). It costs about 0.3 ms for twelve tones, 1 ms for 43 and 1.4 ms for 128 (sclang 3.14.1 on a desktop; the engine check posts the times), a handful of Signals of 16 KB each. The table's 16 KB is not one of `fixedBufferBytes`' sets (`docs/notes/engine/performance.md`): it is negligible against the memory the high tier leaves.

**A sound change from 3.7** (3.8 ruling 37): 3.7 rounded a grain's note to the whole note, then moved that note to its pitch class's nearest tone; the table holds the nearest allowed tone to the grain's own note, as Lua's snap always did. Chromatic, the two agree but at the exact half semitones (where a tie now goes down); with a scale, about a sixth of fractional pitches (a quantized voice with jitter, a fractional pitch shift or a bend before the quantize) land a tone from where 3.7 put them.

**Lua's side.** `lib/tuning.lua` alone sends `setTuning` and `setTuningTone` (the count, then each tone, up to 129 messages, direct, outside the modulation budget), whenever the tuning param's action runs; `lib/variation.lua` sends `setScale` from the `scale`, `root` and `scale_mask` actions. A buffer voice's `scaleNote` handling (`scaleNoteFor`, `noteScaleNote`) is unchanged: `docs/notes/engine/variation.md`.

## Checks

`test/engine_check/tuning.scd` (about 10 s; in the `modulation,freeze,envelopes,tuning` CI shard; it builds no engine of its own) reads the table back with `loadToFloatArray` and compares each frame with the nearest tone found by brute force:
- the table has `tuningTableFrames` frames and starts at twelve equal steps, chromatic from C: every frame the nearest whole note, a tie down, exactly; and where 3.7's quantize (`round`) lands but at the 410 half semitones;
- C major and D major (the mask from the root) give the nearest scale tone, a tie down; a bad root or mask changes nothing and prints nothing;
- 19 equal steps land every frame on the nearest 19-EDO pitch from C4 (frames at a midpoint left out); the mask changes nothing there; ji normal with C major lands on the just major tones; twelve tones of a 1300-cent period ignore the mask;
- eleven of twelve tones, a set that does not ascend, a tone 0 that is not 0, a tone at the period, a non-finite tone, `setTuning` with a count of 0 or 129 or a period of 99, 4801 or nan, a tone past the count and a tone with no set begun each keep the table and the tuning, with the expected number of console lines (none for the incomplete set); tones in reverse order complete a set;
- a table builds in under 50 ms (the mean of ten builds of 12, 43 and 128 tones, posted in the check's line);
- a quantized voice in 19 equal steps at pitch jitter 6 lands every grain within 0.03 semitones of a 19-EDO tone (the timecode probe of `variation.scd`, with defs of its own);
- the table's bufnum never changes.

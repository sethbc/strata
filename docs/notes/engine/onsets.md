## Must not break

- **No sclang function per sample** (#131, [files.md](files.md)): the chunk loop of `onsetStrengths` and every method of `StrataOnsets.sc` it calls (`hopEnergies`, `onsetChunkStrengths`) hold no `do`, `collect`, `fill`, `inject`, `.sum(`, function literal with arguments, `maxItem` or `minItem`; each hop's energy and strength are C primitives over a chunk (`squared`, `copySeries`, Signal arithmetic, `thresh`, `max`, `min`, `overWrite`). A source scan in `test/unit/structure_test.lua` enforces it (`"the onsets pass runs no sclang function per sample (#131)"`).
- **Every `readData` reads into a fresh array** (`freshReadArray`), and **the chunk loop waits through `yieldToCommands`** after each chunk, never a plain `wait` ([files.md](files.md)). A 300 s pass lets a command in within a chunk's time (`"onsets: a 300 s slot's pass yields to commands"`).
- **Nothing grows**: the kept candidates are in two arrays made once with room for `onsetCandidates` (63); the hops' strengths are one `Signal` made once with room for every hop of the slot; a chunk's arrays are its own.
- **The guard**: every step of a pass (after the server's writes, after each chunk, before the file, after its rename) runs only while `slotChanges[index]` is what it was at the command, so a load, a clear or a recording sent meanwhile wins: the pass stops at its next step, deletes its temporary files and reports failed, and leaves no file (one renamed into place after a change is deleted). A slot with no audio (`bufferFrames` 0, a load still under way included) or one that records (`slotRecording`) is refused at once with a failed report.
- **The report comes after the file**: `bufferOnsets` is updated for a pass that wrote its file only from `renameIntoPlace`'s `finish`, once the file is in place, as a load's length follows its peaks file. Every `analyzeBuffer` with a slot in range is reported exactly once, written or failed; an engine that has been freed (`stop`) reports nothing more.
- **File writes** go to `buf<n>.onsets.<instanceTag>-<count>.part` in the settings folder (`allocSettingsDirectory`) and are renamed through `renameIntoPlace` (the waveform area's mover), never a `unixCmd` of their own; the temporary float files are `strata-buf<n>-<instanceTag>-onsets<count>-<L|R>.wav` in `Platform.defaultTempDir`, which `deleteStaleParts`' pattern (`strata-buf*-*.wav`) already sweeps after a crash.
- `bufferOnsetsValue` stays one line of the shape `name { arg ...; ^expr }`: the docs test evaluates it to feed Lua's handler, as it does the other polls'.
- The candidates of a pass are transient: never params, scene fields or PSET values (design 3.7 §3.3).

## Owns

`lib/engine/StrataOnsets.sc` (`strataAreaOnsets`, order 180): the `analyzeBuffer` command and the `bufferOnsets` poll. Its state, `areaState[\onsets]`: `\analyses` (per slot, the `analyzeBuffer` commands received, counted from 1 as Lua counts them; the count names the report), `\poll`, `\chunks` (the chunks every pass has read since alloc, for the check), `\chunkWait` (nil on norns: the check slows a pass with it) and `\stopped` (true from the area's `stop`).

Its literals: `onsetHopFrames` 256 (a power of two, below), `onsetCandidates` 63 (with the marker at 0, at most 64 slices), `onsetGapSeconds` 0.03, `onsetChunkFrames` 16384 (64 hops), `onsetFloor` 1e-6 × the hop's frames, `onsetStrengthCeiling` 1e9 (a NaN or an infinity in the audio never reaches the scaling).

## The pass

`analyzeBuffer(slot)` checks the slot (out of range: one line through the modulation area's `fastModIndicesValid`, nothing counted), counts the analysis and, unless it refuses the slot, has the server write the valid region of both channels to temporary float files (`/b_write`, as a save's first stage, `writeSlot`), then forks `runOnsetPass` on `SystemClock` through `areaCall`. After `context.server.sync` the routine reads the two files in chunks of `onsetChunkFrames`:

1. **Each hop's energy** (`hopEnergies`): the chunk's samples `squared`, then summed in pairs eight times over (`copySeries` of the even and the odd elements, added), so each of the 64 sums is one hop's. Signal's `integral` is one sum of the whole Signal (`_SignalIntegral` returns a Float), not a running sum, so it cannot give the hops' ends; the pairwise sums give the same energies with no running total's rounding. The two channels' energies are added. The last part hop of the slot is left out.
2. **Each hop's strength** (`onsetChunkStrengths`): a hop is a candidate when its energy is above `onsetFloor` (`thresh`) and more than twice the mean of the four hops before it (the four before a chunk are carried from the one before it; before the slot's first hop, its own energy stands in, so it is never a candidate). The mean counts as at least half the floor, so a hop above the floor after silence is a candidate whose strength is in proportion to its energy. Its strength is the ratio less 2, `max` 0, `min` `onsetStrengthCeiling`. The chunk's strengths are written into the slot's strengths Signal (`overWrite`).
3. **The kept** (`pickOnsets`): the strongest hop (Signal's `peak`, its index by `indexOf`), then every hop nearer than the gap (`onsetGapSeconds` at the slot's rate, rounded up to whole hops: 6 at 48 kHz) cleared, and again, at most `onsetCandidates` times: one sclang step per candidate kept, the rest C primitives over the hops. Each is placed at its hop's first frame.
4. **The file** (`onsetsText`, `writeOnsetsFile`): `<settings folder>/buf<n>.onsets`, the frames in ascending order and each strength over the strongest's, with three decimals (`peakText`, so the strongest is `1.000`); both lists end at their key when there is none:

   ```
   strata-onsets 1
   slot 3
   frames 768000
   rate 48000
   onsets 14336 28160 ...
   strengths 0.412 1.000 ...
   ```

   `frames` is the slot's valid length and `rate` its own rate, so Lua can tell a file for other audio. The rename's end reports (`bufferOnsetsValue`: `((count * 2) + failed) * numBuffers + index`).

A second `analyzeBuffer` of the same slot while a pass runs starts a pass of its own; both run to their reports, and Lua acts on the newest only.

## Times

Measured on a desktop at 3.7, on SuperCollider 3.14.1 and 3.13 alike (the check prints both): a 16 s slot's pass reports in about 0.08 s, a 300 s slot's in 0.6-0.7 s, most of it the server's write of the temporary files (115 MB of float for 300 s); every message sent during the 300 s pass (one each 10 ms) was handled within 0.8 ms. Not measured on a Pi.

## The check

`test/engine_check/onsets.scd` (about 5 s, in the `record,waveform,onsets` CI shard) loads float WAVs of single-sample clicks at known frames and levels: eight at 0.25 s steps, each found at its hop's first frame with its strength in proportion to its energy; silence and a steady tone (none); 200 clicks 10 ms apart of rising level (no two kept nearer than 30 ms, the strongest kept, against the same greedy order worked out in the check); 100 clicks 40 ms apart, each after silence (the last 63 kept). It reads the report's arrival with an `OSCFunc` on `/poll/value` (the file is there by then), interrupts slowed passes with a clear, a load and a recording (failed, stopped at once, nothing left), checks the refusals, a 300 s pass on a high engine of its own with a message every 10 ms, and an index out of range. It starts the `bufferOnsets` poll for its time and stops it again, so the runner's poll check sees the registry as it was.

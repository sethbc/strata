## Must not break

- `waveformPoints` (64) equals Lua's `WAVEFORM_POINTS` (`lib/constants.lua`); a test reads both.
- `peaksPath(index)` is under `allocSettingsDirectory`, the folder this engine used at alloc, never `settingsDirectory`: `buildEngine` restores `settingsDir` after a build, so `settingsDirectory` would write peaks into `~/dust` from the check.
- The peak buffers (eight 64-frame mono buffers, `areaState[\waveform][\peakBuffers]`, `slotPeakBuffer(index)`) are allocated in `allocState` and freed in the area's `free`, so nothing reads a freed buffer.
- **The peak scan allocates nothing per sample** (#131): only `fileDecodes`' chunk arrays (fresh, bin-aligned) and one 64-value `FloatArray` per load; a bin's peak is `Signal`'s `peak`, a C primitive. `maxItem` and `minItem` are not primitives: `Collection` runs a sclang function for every sample (880 chunks of 16384 stereo frames, a 300 s load: 3.6-3.9 s of sclang against 13-23 ms for `peak`, on 3.13 and 3.14.1). No `abs`, `copyRange`, `collect` or per-bin array either. A source scan in `test/unit/structure_test.lua` enforces it.
- **The peaks file is in place before the length is reported**: `applyLoad` runs its `bufferChanged` as `writeSlotPeaks`'s action, after the rename has ended. A failed write posts `strata: cannot write <path>` and still reports the length (a waveform is a view, never a reason to hold up audio).
- The action runs only if `slotChanges[index]` is unchanged since the write began, so a load, record or clear sent meanwhile wins.
- `rate` is the slot's own (`bufferSampleRates[index]`), so `frames / rate` is the length the slot reports: a file at another sample rate validates in Lua.
- A failed load leaves the peaks and the file as they were; only a load that took effect stores its peaks (`storeSlotPeaks`, from the `FloatArray` its check filled). A failed server read that emptied the slot clears them, as a clear does.

## Owns

`lib/engine/StrataWaveform.sc` (`strataAreaWaveform`, order 140): the peak buffers, `\peaks` (eight 64-value `FloatArray`s, zeros until a load), `\generation` (an engine-wide count of peaks files written), and:

- `peaksPath(index)`: `<settings folder>/buf<n>.peaks`.
- `storeSlotPeaks(index, peaks)`: `peaks` becomes the slot's, in sclang and the peak buffer (one `/b_setn`).
- `writeSlotPeaks(index, frames, action)`: writes `<path>.<instanceTag>-<generation>.part`, renames it with `mv -f` through `unixCmd` (asynchronous, so sclang never waits on a subprocess), then runs `action`. A folder at the path fails the write (`mv -f` would move the file into it and succeed), as in `writeSlot`.
- `readSlotPeaks(index, usedBins, action)`: one `/b_getn` of 64 floats, the first `usedBins` spread over 64 (`spreadPeaks`, each new bin the largest of the old bins it covers, integers only), stored in `\peaks`. With `usedBins` under 64 the spread also goes back into the peak buffer (`storeSlotPeaks`), so sclang and the buffer keep one overview: a later playable recording starts from the buffer, and a 64-bin refresh reads it. A reply arriving after the slot changed stores nothing, and `action` runs either way: guarding its own steps is the caller's job (the record package's calls arrive on main when 1a merges; until then only the checks call this hook).
- `clearSlotPeaks(index)`: zeros in sclang and the peak buffer. No file: Lua draws nothing for an empty slot.

The scan itself is in `lib/engine/StrataFiles.sc` (`fileDecodes`, with its `peaks` argument): chunks of at most `loadCheckFrames` that end at bin boundaries (`peakBinEnd`, integers, every frame in exactly one bin), at most 64 more reads than the check alone. A file shorter than 64 frames fills only the bins its frames reach: the empty bins are skipped, never read.

## The file

```
strata-peaks 1
slot 3
frames 768000
rate 48000
generation 41
peaks 0.012 0.250 0.731 ... (64 values, three decimals)
```

`slot` is 1-based, like the `n` of `buf<n>.peaks`. Lua (`lib/waveforms.lua`) reads it on a `bufferState` report whose seconds changed to non-zero, and treats it as valid only if the header says version 1 and slot n, there are 64 values in 0-1, and `frames / rate` is within 0.01 s of the reported seconds. Two writes to one slot in flight at once could finish out of order, since nothing spaces them (back-to-back short loads can overlap). Each is a few hundred bytes and a rename, so the window is milliseconds, but an older file that lands last stays in place until the slot's next write, and Lua re-reads only when the slot's reported seconds change, so with an unchanged length the overview can stay stale. `deleteStaleParts` covers the settings folder (`stalePartDirs`), so a `.part` a crash left goes at the next alloc once older than `stalePartAge`.

## Checks

`test/engine_check/waveform.scd`: a load's peaks against a file of known per-bin maxima (short, and long through the yielding check, both from a start past a loud prefix), the record take's spread over 64, the file's format and rising generation, the order of file and report (an `OSCFunc` on `/poll/value`), a slot change during a write dropping its action, the settings folder, the rename (a hard link keeps the old text), a clear, a stale `.part`, a failed write, a failed load, a 22050 Hz file, a 10-frame file, and three 300 s load-and-save pairs on a high engine (about 2.4 s each in Docker; run on 3.13 too).

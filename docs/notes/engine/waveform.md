## Must not break

- `waveformPoints` (64) equals Lua's `WAVEFORM_POINTS` (`lib/constants.lua`); a test reads both.
- `peaksPath(index)` is under `allocSettingsDirectory`, the folder this engine used at alloc, never `settingsDirectory`: `buildEngine` restores `settingsDir` after a build, so `settingsDirectory` would write peaks into `~/dust` from the check.
- The peak buffers (eight 64-frame mono buffers, `areaState[\waveform][\peakBuffers]`, `slotPeakBuffer(index)`) are allocated in `allocState` and freed in the area's `free`, so nothing reads a freed buffer.
- **The peak scan allocates nothing per sample** (#131): only `fileDecodes`' chunk arrays (fresh, bin-aligned) and one 64-value `FloatArray` per load; a bin's peak is `Signal`'s `peak`, a C primitive. `maxItem` and `minItem` are not primitives: `Collection` runs a sclang function for every sample (880 chunks of 16384 stereo frames, a 300 s load: 3.6-3.9 s of sclang against 13-23 ms for `peak`, on 3.13 and 3.14.1). No `abs`, `copyRange`, `collect` or per-bin array either. A source scan in `test/unit/structure_test.lua` enforces it.
- **The peaks file is in place before the length is reported**: `applyLoad` runs its `bufferChanged` as `writeSlotPeaks`'s action, after the rename has ended. A failed write posts `strata: cannot write <path>` and still reports the length (a waveform is a view, never a reason to hold up audio).
- The action runs only if `slotChanges[index]` is unchanged since the write began, so a load, record or clear sent meanwhile wins.
- **A peaks write never forks sclang while the mover lives** (#210): its rename goes to the peaks mover through the FIFO, never `unixCmd` or `systemCmd` (a fork holds sclang about 2.5 ms per 130 MB of its memory). sclang's end of the FIFO is opened `"r+e"` after the mover starts: read-write, so sclang always holds a reader and a dead mover can never SIGPIPE it (that kills sclang), and close-on-exec, so no later child holds it open and the mover ends on EOF when `free` closes it. At most `peaksMoverBacklog` (8) lines wait in the FIFO, so a write to it never blocks. A rename the mover has not done within `peaksMoverTimeout` (1 s) goes by a subprocess and the mover is used no more.
- `rate` is the slot's own (`bufferSampleRates[index]`), so `frames / rate` is the length the slot reports: a file at another sample rate validates in Lua.
- A failed load leaves the peaks and the file as they were; only a load that took effect stores its peaks (`storeSlotPeaks`, from the `FloatArray` its check filled). A failed server read that emptied the slot clears them, as a clear does.

## Owns

`lib/engine/StrataWaveform.sc` (`strataAreaWaveform`, order 140): the peak buffers, `\peaks` (eight 64-value `FloatArray`s, zeros until a load), `\generation` (an engine-wide count of peaks files written), `\mover` (the peaks mover: `alive`, `exited`, `freed`, `pending` lines, `pid`, `file`), and:

- `peaksPath(index)`: `<settings folder>/buf<n>.peaks`.
- `storeSlotPeaks(index, peaks)`: `peaks` becomes the slot's, in sclang and the peak buffer (one `/b_setn`).
- `writeSlotPeaks(index, frames, action)`: writes `<path>.<instanceTag>-<generation>.part`, renames it with `mv -f` (`renamePeaksFile`), then runs `action`. A folder at the path fails the write (`mv -f` would move the file into it and succeed), as in `writeSlot`.
- `renamePeaksFile(partPath, path, finish)`: through the mover when it is alive, fewer than `peaksMoverBacklog` lines are pending and neither path holds a newline: the two lines go to the FIFO (a write and a flush, 0.004-0.08 ms), then a `SystemClock` poll every 2 ms runs `finish` once the `.part` is gone (the rename is atomic, so the file is in place). Otherwise, or after `peaksMoverTimeout`, `renameBySubprocess` (`mv -f` through `unixCmd`, the 3.3 path). A mover's failed `mv` deletes the `.part` and posts `strata: cannot write <path>` itself.
- `startPeaksMover` (in `allocState`) and `stopPeaksMover` (in `free`), below.
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

`slot` is 1-based, like the `n` of `buf<n>.peaks`. Lua (`lib/waveforms.lua`) reads it on a `bufferState` report whose seconds changed to non-zero, and treats it as valid only if the header says version 1 and slot n, there are 64 values in 0-1, and `frames / rate` is within 0.01 s of the reported seconds. The mover renames in the order the writes were made, so two writes to one slot land in order. Only a rename by subprocess (no mover, or after its timeout) can finish out of order with another: each is a few hundred bytes and a rename, so the window is milliseconds, but an older file that lands last stays in place until the slot's next write, and Lua re-reads only when the slot's reported seconds change, so with an unchanged length the overview can stay stale.

## The peaks mover

A playable recording refreshes its peaks file every `peakRefreshSeconds` (0.5 s). Each refresh used to rename its `.part` with a `unixCmd` of its own, and `unixCmd` forks sclang: 2.2-2.7 ms at sclang's usual 130 MB, 4.5 ms at 197 MB, 9.5 ms at 394 MB (3.13, x86), plus copy-on-write faults after it, so a refresh held sclang 4-6 ms and a command from Lua arriving then waited (#210). `systemCmd` is no fix: it waits for `mv`, and on norns' glibc 2.28 it forks too.

`startPeaksMover` makes a FIFO, `<settings folder>/strata-peaks-mover.<instanceTag>.part` (`peaksMoverPath`; any old file at that name goes first, since `instanceTag` restarts with sclang), and starts one shell for the engine's life with `unixCmd` (its exit action sets `alive` false and `exited` true): `exec sh -c '<loop>' <fifo> < <fifo>`. Its loop removes the FIFO's name, then reads two lines at a time, the `.part` and the path, and runs `mv -f` for each pair. Only then does sclang open its end, `File(fifo, "r+e")`; the shell's open returns once sclang's is made, and alloc waits (2 ms steps, at most 1 s) until the name is gone, so no listing of the folder finds it later. The name ends in `.part` and never matches `*.peaks.*.part`, so a crash between `mkfifo` and the shell's open leaves a file `deleteStaleParts` cleans. If `mkfifo` or the open fails, the engine posts `strata: no peaks mover (...)` and every peaks write renames by subprocess.

`stopPeaksMover` sets `freed`, closes sclang's end and forgets it: the mover renames what it has read, reads EOF and ends (about 10 ms). A poll still waiting when the engine is freed stops without running its action.

Measured after (3.13 in Docker, x86): `writeSlotPeaks`' synchronous part 0.46 ms median, 0.71 ms at most (before: 4.1-5.6 ms); during a loop recording, a 1 ms `SystemClock` task's longest gap 1.57 ms (baseline 1.12 ms; before: 4.1-5.9 ms); a message sent as a refresh starts is handled within 0.84 ms (before: 5.56 ms). `deleteStaleParts` covers the settings folder (`stalePartDirs`), so a `.part` a crash left goes at the next alloc once older than `stalePartAge`.

## Checks

`test/engine_check/waveform.scd`: a load's peaks against a file of known per-bin maxima (short, and long through the yielding check, both from a start past a loud prefix), the record take's spread over 64, the file's format and rising generation, the order of file and report (an `OSCFunc` on `/poll/value`), a slot change during a write dropping its action, the settings folder, the rename (a hard link keeps the old text), a clear, a stale `.part`, a failed write, the peaks mover (its FIFO's name gone, a write through it, a stopped mover timing out into a subprocess rename, a killed one, free ending it), a failed load, a 22050 Hz file, a 10-frame file, and three 300 s load-and-save pairs on a high engine (about 2.4 s each in Docker; run on 3.13 too).

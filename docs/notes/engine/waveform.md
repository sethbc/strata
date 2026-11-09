## Must not break

- `waveformPoints` (64) equals Lua's `WAVEFORM_POINTS` (`lib/constants.lua`); a test reads both.
- `peaksPath(index)` is under `allocSettingsDirectory`, the folder this engine used at alloc, never `settingsDirectory`: `buildEngine` restores `settingsDir` after a build, so `settingsDirectory` would write peaks into `~/dust` from the check.
- The peak buffers (eight 64-frame mono buffers, `areaState[\waveform][\peakBuffers]`, `slotPeakBuffer(index)`) are allocated in `allocState` and freed in the area's `free`, so nothing reads a freed buffer.

## Owns

`lib/engine/StrataWaveform.sc` (`strataAreaWaveform`, order 140): the peak buffers, `\peaks` (eight 64-value `FloatArray`s of zeros), `\generation` 0, `peaksPath(index)`, and the neutral hooks 3.3's waveform package (1b) fills: `writeSlotPeaks(index, frames, action)` and `readSlotPeaks(index, usedBins, action)` run `action` at once, `clearSlotPeaks(index)` does nothing. A waveform check that needs more (a peak scan, a 300 s soak) is 1b's.

## Must not break

- `slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_scanReset)` (neutral) is 3.2's scan, exactly: `Phasor.ar(0, this.scanRate(bufScan, freeze) * SampleDur.ir, 0, 1)` (`"positions: slotScanPhase is 3.2's scan"`). `scrubRate`, `scanHold` and `t_scanReset` are the grain controls 3.3's positions package (1c) uses; every `\strataGrainBuf` has them.

## Owns

`lib/engine/StrataPositions.sc` (`strataAreaPositions`, order 150): `slotScanPhase`, called by `slotGrainReader` (`StrataGrainDefs.sc`). No state, defs or commands yet.

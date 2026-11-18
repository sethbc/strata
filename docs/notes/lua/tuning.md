## Must not break

- **`TUNING` mirrors the engine's tuning constants** (`tuningMaxTones`, `tuningMinPeriod`, `tuningMaxPeriod`, `octaveCents`, `tuningTwelve`, `tuningOctaveTolerance`, `tuningRootKey`, `tuningTableFrames`, `tuningTableLow`, `tuningTableResolution`, `docs/notes/engine/tuning.md`), and `TUNING.default` is the tuning the engine starts in (a docs test compares both).

## lib/tuning.lua (`S.lib.tuning`)

The one tuning (3.8, design §6). `M.TUNING` holds its constants.

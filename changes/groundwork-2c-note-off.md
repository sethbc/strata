### Changed
- MIDI note off has two modes, `latch` (the default) and `release`, in every channel mode; `auto`, which released only in the MPE modes, is gone. An MPE player sets `release` once: a PSET saved with `auto` now latches, one saved with `release` still releases, and one saved with `latch` reads as `release`.

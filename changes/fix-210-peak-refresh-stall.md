### Fixed
- A recording no longer stalls the engine every half second: each waveform refresh used to start a subprocess, which held up notes, param changes and grid presses for several milliseconds (more on a norns); one long-lived helper now renames the peaks files (#210).

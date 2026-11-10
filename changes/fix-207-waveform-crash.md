### Fixed
- The engine check no longer crashes sclang 3.13 in the waveform area: its 300 s test file is written from one chunk built once, instead of a new chunk for every 65536 frames (#207).

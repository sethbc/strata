### Fixed
- A freeze read the engine could not answer in time no longer leaves a listener behind for each read that gave up (#1014).

### Changed
- The engine names what a voice's freeze holds in one place, so a voice frozen on a slot or the input and moved to its synth while stopped is never taken for a frozen synth voice (#887); a type switch sent to a stopped, spectral-frozen voice is now checked (#979).

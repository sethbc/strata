### Fixed
- A freeze's read of a ring's position no longer leaves a listener behind when the audio server does not answer in time, nor a timer running when it does (#1014).

### Changed
- The engine names what a voice's freeze holds in one place, so a voice frozen on a slot or the input and moved to its synth while stopped is never taken for a frozen synth voice (#887); a type switch sent to a stopped, spectral-frozen voice is now checked (#979).

### Fixed
- Spectral freeze no longer risks crashing SuperCollider on norns: its FFT buffers are now allocated once per voice instead of inside the synth, which corrupted memory in SuperCollider 3.13.

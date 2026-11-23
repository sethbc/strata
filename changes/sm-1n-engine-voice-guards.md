### Fixed
- A voice whose mix stage is reset after bad values while the audio server is out of memory no longer stays silent until a restart: if the new stage does not start within half a second, the engine starts it again.
- A voice whose synth keeps ending as soon as it starts is no longer restarted without end: after 32 restarts within a second the engine stops restarting it and prints one line, and the voice's next start plays it again.
- A note slot the engine finds playing with no synth is left alone with one console line, instead of an error when the note is released or played again.

### Changed
- The engine's areas share one "stopping" flag when the engine is freed, in place of four flags of their own. Nothing changes in what you hear.

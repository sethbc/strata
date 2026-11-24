### Changed
- The engine check's synced-recording test reads the engine's own start time, so a busy machine no longer fails it by one block (#1017).

### Fixed
- A freeze sent the moment the engine starts no longer risks crashing the audio server or leaving a voice's ring held after its unfreeze (#1018).

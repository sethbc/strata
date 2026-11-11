### Changed
- The FM and Ring voices take out what lies under 15 Hz before their voice bus: at a ratio near 1 a sideband or difference tone near 0 Hz no longer reaches the grains (where it became a rumble at the grain rate), crossmod, the effects or the master's limiter. Default patches measure the same; a 20 Hz FM or Ring note is up to 1.2 dB quieter (#309).

### Fixed
- A voice whose synth the server could not start (no room in its real-time memory) gets it again at its next start, instead of staying silent through every stop and start (#497).
- A synth that fails to start is reported in maiden even when the same start brings back synths still in their release (#498).
- A script whose engine fails partway through loading no longer leaves the engine's buffers, buses and nodes allocated until norns restarts, and an error while the engine is freed no longer leaves the rest of it allocated (#499).
- The engine refuses grain and voice params that name a control it sets itself (such as `kill`), which a slip in a script would otherwise have kept for good (#458).
- A voice param no longer sends an empty message to the grain synth of a voice playing a buffer or the live input (#501).

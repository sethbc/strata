### Changed
- The buffers' behavior is now written down and tested as a table: every state a buffer slot can be in (empty, loading, armed, recording, finishing, loaded, unsettled, missing and their sub-states) by everything that can happen to it, with the settings that follow a slot, the scan hold and the arc scrub's glide; nothing a player hears or sees changes.

### Fixed
- A take synced to the beat (or armed by a level) and stopped with K3 before it started no longer becomes `take <n>` when the engine's answer never arrives: after 5 s the buffer is as it was before the take (its file back, or empty if the take had already emptied it).

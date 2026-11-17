### Changed
- The SCENES page's third chance reads `random`, as SEQ's chain chance does (it read `rand`).
- The scene sequencer, the pattern chain and the next-scene action (crow, OSC, Teletype) share one list of playable scenes and one draw of the next. A chain whose playing scene has been cleared goes on to the next saved scene with no draw, as the scene sequencer does.

### Fixed
- A random chain move that landed on a damaged saved scene no longer walks on from it (which picked the scene after it about twice as often and could reload the playing scene); a damaged scene is never drawn (#738).
- The scene sequencer never draws a damaged saved scene, so it no longer holds one for a scene duration with nothing applied (#754).
- A one-shot step slice is shown again (the grid's slice row, the slice editor) when its scan restarts, as it plays (#740).
- A ping-pong pass shortened partway finishes its leg before turning at the new length when the leg is already past it, as reverse does (#743).
- On an overlap voice, a step slice refused an extra slot (the note pool at 0 or full) plays its own slice on the voice's own note, instead of restarting the slice still ringing there (#744).

### Changed
- The SCENES page's third chance reads `random`, as SEQ's chain chance does (it read `rand`).
- The scene sequencer, the pattern chain and the next-scene action (crow, OSC, Teletype) share one list of playable scenes and one way of picking the next: the sequencer and the chain draw it from their chances, and the next-scene action steps to the next scene that can play. A chain whose playing scene has been cleared goes on to the next saved scene with no draw, as the scene sequencer does.

### Fixed
- The pattern chain never picks a scene that fails its check, and a move past one no longer favors the slot after it or reloads the playing scene (#738).
- The scene sequencer never picks a scene that fails its check, so it never holds one for a scene duration with nothing applied (#754).
- A one-shot step slice is shown again (the grid's slice row, the slice editor) when its scan restarts, as it plays (#740).
- A ping-pong pass shortened partway finishes its leg before turning at the new length when the leg is already past it, as reverse does (#743).
- On an overlap voice, a step slice refused an extra slot (the note pool at 0 or full) plays its own slice on the voice's own note, instead of restarting the slice still ringing there (#744).

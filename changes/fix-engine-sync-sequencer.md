### Added
- The patterns follow the clock's transport: a start from the clock source (a MIDI start, a Link start with start/stop sync on, or PARAMETERS > CLOCK > reset) plays them from step 1 on its first beat, and a stop stops them (#530).

### Fixed
- A started voice's first grain plays its new position, loop, envelope and grain mode: the source and every grain value now reach the engine before the voice starts, so no stray grain from the last run is heard, and a voice switched to triggered mode while stopped no longer plays an unasked grain when it starts (#325).
- A voice whose start fails partway is stopped again, so the engine and the screen agree that it is off and the next press starts it (#382).
- A pattern step that starts several voices repaints the grid once, not once per voice (#527).
- The crossmod params of the three slots are built from one definition, so they cannot drift apart (#392); a toggled or random pattern step takes its levels from the step level range (#418).

### Added
- The patterns follow an external clock's transport: with the clock source on MIDI or Link, a start from it (a MIDI start, or a Link start with start/stop sync on) plays them from step 1 on its first beat, and a stop stops them. On the internal clock, PARAMETERS > CLOCK > reset leaves them as they are (#530).

### Fixed
- A started voice's first grain plays its new position, loop, envelope and grain mode: the source and every grain value now reach the engine before the voice starts, so no stray grain from the last run is heard, and a voice switched to triggered mode while stopped no longer plays an unasked grain when it starts (#325).
- A voice whose start fails partway is stopped again, so the engine and the screen agree that it is off and the next press starts it (#382).
- A pattern step that starts several voices repaints the grid once, not once per voice (#527).
- The crossmod params of the three slots are built from one definition, so they cannot drift apart (#392); a toggled or random pattern step takes its levels from the step level range (#418).

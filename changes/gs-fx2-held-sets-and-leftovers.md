### Fixed
- A move voice's held step value now ends at any change of its setting from outside the sequencer, as a turn by hand does: a mapped MIDI controller, OSC, a morph, a scene's transition, a mutation, a randomize or its undo is heard at once. The drift still wanders underneath the value without ending it.
- Undoing a randomize on a move voice takes back the random values it gave the steps it turned on, so a step tapped on again later moves nothing it should not.

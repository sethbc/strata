### Fixed
- A synth on a MIDI port a remote grid, a remote arc or `midi grid` holds no longer keeps hanging notes when Strata ends: Strata lets those ports go first, so the synth gets the note offs it was still owed, and its MPE zone is turned off with no setup first (#1010).

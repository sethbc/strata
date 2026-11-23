### Changed
- Tests and notes only, nothing a player hears or sees: the order in which the MIDI modules hear a device arrive, leave, get claimed or released and get moved in SYSTEM > DEVICES, and what a MIDI out note does at each of those, are now tables a test checks; the ii bus, crow, the controllers, nb, OSC and MIDI out's zones each have a self-check the tests run; and the notes list the seven start and cleanup flags of the outside-device modules.

### Fixed
- The controllers (an E16 or a fader box) no longer take their MIDI port back if a rig setting changes after the script has ended (#972).

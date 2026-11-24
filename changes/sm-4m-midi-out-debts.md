### Fixed
- MIDI out: a note sent to a synth at a port it visits while the norns menu is open (SYSTEM > DEVICES), the synth moved on or back before the menu closes, gets its note off as the menu closes; before, it hung until the synth was plugged in again (#988).
- MIDI out: a synth on a port a remote grid, a remote arc or `midi grid` holds keeps the note offs it is owed, and gets them once the port is let go or on the port it next turns up on; before, they were lost and the notes hung (#996).
- MIDI out: a synth owed two notes of one pitch on one channel (sent at two ports while the menu was open) gets two note offs when it comes back, not one (#997).

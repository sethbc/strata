### Fixed
- MIDI out: a note played while a remote grid, a remote arc or `midi grid` holds its port no longer sends a note off once the port is let go (the device never got the note), and a note still sounding on a port as one of them takes it now gets its note off then, so the synth there is not left holding it (#769).

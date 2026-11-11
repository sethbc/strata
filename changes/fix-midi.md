### Fixed
- Every norns MIDI port (1-16) can be chosen on SETUP and in PARAMETERS, not only 1-4.
- A key held across a MIDI channel mode change still releases the voice it started; unplugging the keyboard or changing the port stops the voices its held keys were holding (voice off mode).
- MIDI all notes off (CC 123) and all sound off (CC 120) release every held note and stop the voices those keys held.
- Plugging a MIDI device in while the script loads no longer prints a Lua error.

### Changed
- A beat- or bar-quantized gesture loop waiting for its next pass starts on a transport start's first beat (a MIDI or Link start, PARAMETERS > CLOCK > reset) instead of a whole loop later.
- With quantize actions on beat or bar, pressing a freeze key or the play key again while its action waits takes the action back, and a transport start or stop drops a waiting pattern start, so the patterns never start twice on a MIDI or Link start, nor after a stop.

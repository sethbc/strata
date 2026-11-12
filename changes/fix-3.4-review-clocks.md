### Changed
- A beat- or bar-quantized gesture loop waiting for its next pass starts on a transport start's first beat (a MIDI or Link start, PARAMETERS > CLOCK > reset) instead of a whole loop later.
- With quantize actions on beat or bar, pressing a freeze key or the play key again while its action waits takes the action back, and a transport start or stop drops a waiting pattern start, so the patterns never start twice on a MIDI or Link start, nor after a stop.
- A quantized scene recall at the bar that stops a beat- or bar-quantized gesture loop, a stop of such a loop as its beat comes, or a quantized action replaced or taken back just as its beat comes no longer prints `bad argument #1 to 'resume'` in maiden.

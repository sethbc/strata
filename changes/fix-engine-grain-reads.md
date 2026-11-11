### Fixed
- A buffer voice with reverse between 0 and 100%, size jitter or pitch jitter no longer plays grains that run into the silent rest of the buffer or wrap into its other end (clicks, dips and splices of unrelated audio).
- A synth or input voice's grain that started just as the voice's loop of recent audio came round no longer plays from up to a whole loop back (for an input voice, input from up to 21 s ago, past the history limit).
- A loop or overdub recording into a buffer that once held a 22.05, 44.1 or 96 kHz file no longer clicks where slow, fast or reversed grains meet the record head.
- A buffer voice at a buffer position of exactly 1 (the encoder's end stop, a bookmark at 1.000, an LFO at the top) plays the end of its loop, as the screen says, instead of its start.
- Freezing or unfreezing an input voice no longer plays a stray grain from a point between the live input and the frozen audio.
- A flood of retriggers in triggered grain mode (a MIDI flood) no longer overloads a voice's grains: a trigger within 4 ms of the last grain's start starts none, so two notes on one voice within 4 ms (a chord whose notes arrive a little apart) now give one grain. Pattern steps (at least 50 ms apart) and continuous grains (at most 200 a second) never lose one.

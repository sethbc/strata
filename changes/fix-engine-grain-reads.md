### Fixed
- A buffer voice with reverse between 0 and 100%, size jitter or pitch jitter no longer plays grains that run into the silent rest of the buffer or wrap into its other end (clicks, dips and splices of unrelated audio).
- A synth or input voice's grain that started just as the voice's loop of recent audio came round no longer plays from up to a whole loop back (for an input voice, input from up to 21 s ago, past the history limit).
- A loop or overdub recording into a buffer that once held a 22.05, 44.1 or 96 kHz file no longer clicks where slow, fast or reversed grains meet the record head.
- A buffer voice at a buffer position of exactly 1 (the encoder's end stop, a bookmark at 1.000, an LFO at the top) plays the end of its loop, as the screen says, instead of its start.

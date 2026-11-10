### Fixed
- A frozen input voice stopped and started again, or started again inside its release, plays its frozen audio from the first grain (it played a moment of the live input, at its history, first).
- A frozen input voice whose grain synth restarts on its own keeps playing its frozen audio, and unfreezing it brings it back to the live input at its history.
- A frozen voice whose freeze mode changed starts frozen when it is next started.

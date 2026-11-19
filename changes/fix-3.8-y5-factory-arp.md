### Fixed
- The arpeggiator: a sequencer step's chord on a voice holding no note of its own keeps its pitches when you turn the voice's `freq`, instead of moving with it until the chord next changed.
- A PSET without scenes (or a factory set) loaded while a scene fades keeps its own sound: the fade now ends at the load, instead of fading the old scene back over it.

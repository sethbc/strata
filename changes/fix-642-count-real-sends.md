### Changed
- Modulation of a stopped voice (an LFO, a macro, a matrix routing, a morph) no longer uses up the engine message budget, so under heavy modulation the running voices' values go out without waiting behind messages that reach nothing.

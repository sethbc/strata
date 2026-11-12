### Changed
- Jittering the morph around the middle (a fader, a mapped CC, a gesture loop) no longer starts and stops voices more than about three times a second: a scene switch the morph has just made holds for 0.3 s while the continuous values keep following it.
- Modulation of a stopped voice (an LFO, a macro, a matrix routing, a morph) no longer uses up the engine message budget or the LFOs' 12 sends a step, so under heavy modulation the running voices' values go out without waiting behind messages that reach nothing.

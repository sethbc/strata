### Changed
- A macro, the morph, a gesture or a fade moving an engine-run LFO's settings shares the LFOs' limit of 12 sends a step and the engine's message budget with all other modulation; a hand edit still reaches the engine at the next step.
- An LFO on a macro moves the macro's grain pitch, position, size, filter and level targets at every LFO step: its own bookkeeping no longer takes a share of the 12 sends a step.

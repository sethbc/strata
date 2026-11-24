### Fixed
- A held buffer or input note whose pitch is outside MIDI's 0-127 (a high key of a tuning with fewer than twelve tones to an octave, say) keeps its pitch when its voice switches to a slot with another key, or leaves a freeze, instead of jumping to the pitch of the nearest of 0 or 127 (#1002).

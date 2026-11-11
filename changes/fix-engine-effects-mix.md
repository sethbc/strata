### Changed
- Every sound is steadier, brighter and somewhat louder: the tape drift's pitch shifter no longer takes 5.7 dB off everything above 1 kHz. Measured at the default drift with reverb 0.3, all seven voices together: +1.8 dB RMS (+4.4 dB above 1 kHz, +1.6 dB below 200 Hz; peaks 0.298 to 0.324); FM, Pulse, Karplus and Ring +3.7 dB (+4.6 dB above 1 kHz), Resonator and Sub +1.4 dB. Saved scenes and PSETs play this way; the limiter and the saturation see more level (#306).
- A filter cutoff that jumps up (a scene recall, a square or random LFO, a controller jump), on the master filter or a voice filter, glides to its new value at 100 octaves a second, the whole range in a tenth of a second; it falls as fast as before. A resonant highpass moved fast rings a little differently (#305).

### Fixed
- The tape drift no longer makes every steady tone flutter by 25-30 dB, at a drift of 0 too: a 1 kHz tone now keeps its level within 0.2 dB at any drift, and a drift of 0 is no drift at all (#306).
- A resonant highpass (or bandpass) whose cutoff jumped up from low, on the master filter or a voice filter, no longer throws a burst up to 60 dB above the signal into the output, the delay and the reverb (#305).
- Lifting the delay's bypass while audio plays no longer clicks one delay time later, nor with each echo: the lifted delay's (and reverb's) input fades in over 50 ms (#308).

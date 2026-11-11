### Fixed
- A scene crossfade of a voice that quantizes to the scale climbs or falls through the scale's tones once, instead of trilling back and forth between two of them; a MIDI-mapped CC, a grid fader and any other set land on the tone nearest their own value. E3, the arc, PARAMETERS and mutations still turn it one scale tone at a time.
- PARAMETERS' fine turn (K3 held) steps Strata's number params (the mod sources, the MIDI device, the sequence length, the record beats, the custom intervals, the LFO depths and offsets, tempo) by whole numbers: they no longer take fractions such as `voice 0.05`, and the MIDI device no longer raises an error.
- A scene recall or crossfade that switches an on/off param (a voice's quantize or freeze, mutations) now sends it to a controller mapped to it in PARAMETERS > MAP.
- The scene sequencer skips an empty slot at once, as documented, instead of waiting on it for the scene duration; the grids light the next scene it will actually recall.
- An error inside the scene sequencer switches it off (its param, the screen and the grids agree) instead of leaving it shown running while it never advances.
- A crossfade to a scene that turns a running LFO off fades that LFO out, instead of fading its depth and rate toward settings the scene never plays.

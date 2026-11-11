### Changed
- A slow LFO on a frequency (a voice's freq, the filter cutoffs) glides in steps of about 8 cents instead of 2 Hz: its send threshold of 1/1000 of the range is measured in octaves on an exponential range (#406). Linear destinations step as before.
- The LFO page's dot swings by the LFO's depth: across the whole wave at 100 %, on its middle line at 0 % (#520).
- ALT+E3 on the LFO page's destination jumps to each voice's history, voice filter cutoff, delay send and reverb send as groups of their own (`v1 hist`, `v1 vfilt`, `v1 dsend`, `v1 rsend`), so the last voice's reverb send is four jumps and six detents from `v7 main`, where it was one jump and 27 detents (#511).
- The LFO page draws every frame only while an LFO runs; with all three off it draws only when something on it changes (#423).
- An LFO's min never goes above its max in PARAMETERS: setting one past the other moves the other with it (#528).

### Fixed
- The LFO page's dot stays with the LFO after a mode change between free and clocked at any tempo, and after a reset to "mid: rising" in free mode (#409, #415).
- A random LFO with its min above its max no longer stops every LFO for the rest of the session (#528).
- An error inside an LFO step, the arc scrub's glide or a mutation step is printed once with its traceback and no longer stops the LFOs, the glide or the mutations (#517).
- The LFO page and modulation docs list every LFO destination, the voices' history, filter and sends included (#340).

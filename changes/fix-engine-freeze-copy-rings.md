### Changed
- A frozen input's copy now lives in a 4 s buffer of its own per voice: Strata takes about 10.8 MB more of the norns' memory on both tiers (not of SuperCollider's real-time pool), and the high tier keeps its longest buffers only with about 10 MB more memory free at start (300 s from 1,993,951 kB available, 120 s from 1,453,951 kB, 60 s from 1,273,951 kB).
- Freezing an input voice within 2 s of switching it from its synth (a scene recall that does both) now holds at once, and the synth's own tail plays out its release instead of ducking for the copy.

### Fixed
- Switching a voice from its synth to the input and freezing it (a scene recall, or a freeze within 2 s of the switch) no longer plays the frozen input a second time at the input's own level, about 9 dB too loud, for a second or two.
- A frozen input voice switched back to its synth, or stopped while frozen and started again on its synth, no longer plays a burst of the frozen input at the input's own level whatever its level is set to.
- Unfreezing a voice always sets its grains back and ends the freeze in the same instant, so no grain plays from the frozen read point on the live input.
- A hand-edited `performance_active.data` or `performance.data` holding a 10-digit number that wraps to a valid length (`4294967356`) is refused by the engine as it is by the script, so the two never run different tiers or lengths.
- The technical page gives the real-time memory the engine uses (about 3.3 MB at the worst moment, with at least 3 MB kept free), says an old active file that cannot be replaced keeps its tier, and draws the per-voice stage and the effect sends; the scenes page says how to save a scene without a grid.

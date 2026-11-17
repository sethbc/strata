### Fixed
- Loading a PSET no longer loses your scenes when the PSET they were last saved with has lost its scenes file (deleted, or a PSET copied without it) or holds other scenes now: they count as in no PSET and are kept as `scenes.data.bak` first, and loading that PSET forgets that it held them (#766).
- A Launchpad under `midi grid`, or a remote grid, no longer gets a note off from MIDI out for a note it never got when it is moved to another port in SYSTEM > DEVICES or plugged in again: a note sent while a remote or `midi grid` held its port owes nothing (#767).
- A synced delay whose clock reports no tempo (an external clock at 0) plays the delay time you set, with its modulation as it is now, instead of an older time left from before sync; and under a synced delay with modulation on its time, a tempo change sends the new time once, not twice (#768).

### Changed
- A PSET whose scenes cannot be loaded over yours (no backup name free, the card refusing, or a scenes file that could not be read at the start) now also says `pset scenes not loaded` on the hint row for a few seconds, beside its console line.

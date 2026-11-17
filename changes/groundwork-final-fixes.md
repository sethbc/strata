### Fixed
- Loading a PSET no longer loses your scenes when the PSET they were last saved with has lost its scenes file (deleted, or a PSET copied without it) or holds other scenes now: they count as in no PSET and are kept as `scenes.data.bak` first, and loading that PSET forgets that it held them (#766).
- A Launchpad under `midi grid`, or a remote grid, no longer gets a note off from MIDI out for a note it never got when it is moved to another port in SYSTEM > DEVICES or plugged in again: a note sent while a remote or `midi grid` held its port owes nothing (#767).

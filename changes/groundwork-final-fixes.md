### Fixed
- Loading a PSET no longer loses your scenes when the PSET they were last saved with has lost its scenes file (deleted, or a PSET copied without it) or holds other scenes now: they count as in no PSET and are kept as `scenes.data.bak` first, and loading that PSET forgets that it held them (#766).

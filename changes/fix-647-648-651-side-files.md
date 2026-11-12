### Changed
- No change for players: the modulation matrix asks the send budget what the engine has or will have, as the LFOs do, so a value another writer left waiting for the same param never reaches the engine after the matrix's newer one.
- No change for players: the macros, the matrix and the gesture recorders read and write their files (data/strata/ and beside each PSET) through one shared helper, so the rules that protect them (a damaged file set aside, one that cannot be set aside never written over) are kept in one place.

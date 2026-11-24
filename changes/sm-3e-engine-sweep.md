### Changed
- Tests only, nothing a player hears or sees: the engine check now sweeps the engine's own bookkeeping after every area (recordings, effect bypasses, LFO and envelope nodes, file writes, slot lengths), and the engine keeps its ring writers in one record instead of two.

### Changed
- Tests only, nothing a player hears or sees: a model of the engine's modulation nodes (the LFOs' nodes, the matrix's fast offsets, the envelope routes, scatter) is checked against what the params imply over seeded random play of the LFOs, the matrix, the envelopes, scenes, fades, source switches and macros, and a step with nothing to do must send nothing (#916).

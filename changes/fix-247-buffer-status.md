### Fixed
- "Fill the empty buffers" no longer loads over a buffer whose file is still waiting for its length from the engine, and the grid no longer dims that buffer's source key as empty: the fill, the BUFFER page and the grid now agree on which buffers are empty (#247).

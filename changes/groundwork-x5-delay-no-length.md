### Fixed
- Development: a synced delay at a tempo that gives no length (an external clock reporting 0), under an LFO or a macro on its time, sends one `setDelay` a step rather than the same value twice; a player hears no difference (#770).

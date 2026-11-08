### Fixed
- A buffer restored at start that the engine first reports as empty no longer stays marked as restoring for the rest of the session; if its audio arrives later it is still counted once in SETUP's restored buffers.

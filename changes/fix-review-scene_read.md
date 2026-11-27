### Fixed

- Reloading the current preset checks its scenes file on disk twice but decodes and validates unchanged contents only once, reducing the time a reload holds up playback controls (#1272).

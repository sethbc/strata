### Fixed
- A recording that keeps the slot's audio (an overdub or a loop), sent in the moment a new take is ending, now waits for that take and records over it, instead of erasing it; a transients analysis sent then is refused as during a recording.
- A synced recording whose start falls a few milliseconds after its preparation now starts; before, it could stay armed until stopped, never recording.
- After a slow file rename, a slot's transients file can no longer be replaced by an older analysis of audio the slot no longer holds.

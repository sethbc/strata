### Fixed
- A clock-synced recording started right after a tempo change gets the new tempo's length and waits for the new tempo's beat or bar, and BUFFER's `len` field shows the new tempo's beats at once; under a MIDI or crow clock both follow the clock's tempo (#567).
- A clock-synced recording sent while the engine is busy (another buffer's file still loading, for example) starts its delay after the moment it was sent, also when several are sent during that wait; before, only the first started on time and the others started late by the rest of the wait (#565).

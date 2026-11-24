### Fixed
- A part of the script that runs when a voice is locked or unlocked (by a key, the grid or a scene), if it ever fails, now prints one line and no longer stops the lock or the scene's recall; the lock is set in one place (#917). This completes #910: every kind of hook a voice's source or lock change runs is now contained.

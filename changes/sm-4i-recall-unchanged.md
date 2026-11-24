### Fixed
- A scene recall, fade or morph no longer resends a value the param already holds: recalling the state in force sent a voice's frequency, its scale note and its attack and release times again, a rounding error off, and capturing and recalling a scene over and over moved the attack and release times by that error each time (#977).

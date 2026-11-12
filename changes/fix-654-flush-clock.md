### Changed
- The engine message budget's flush clock now ends on its own instead of being stopped while norns may be about to wake it, which could print `bad argument #1 to 'resume'` in maiden; nothing a player hears or sees changes.

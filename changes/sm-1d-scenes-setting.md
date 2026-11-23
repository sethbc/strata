### Fixed
- A change made by hand while a scene crossfades is taken as at any other time: a loop length is cut to fit its start (it no longer stays too long, nor goes into a scene saved then), quantized pitches snap to a new scale or root, and a grid shows a moved effects fader at once instead of at the crossfade's next step (#867).
- SETUP keeps saying a scenes file that could not be read at start was kept as `scenes.data.bak` after one failed save and a good one; before, the row went for the rest of the session though the backup was still on the card (#868).

### Changed
- A scene's recall puts its "a scene is applying" mark back as it found it, so an apply made inside another (none does yet) leaves the outer one's in place (#892).

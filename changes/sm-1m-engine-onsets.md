### Fixed
- Analyzing a slot's transients again while an analysis runs ends the older pass at once, so turning the slice editor's sensitivity on a long slot no longer runs several passes at once.
- An older analysis that finishes after the slot changed no longer deletes the transients file a newer analysis has just written.
